// Compiler implementation of the D programming language
// Copyright (c) 1999-2015 by Digital Mars
// All Rights Reserved
// written by Walter Bright
// http://www.digitalmars.com
// Distributed under the Boost Software License, Version 1.0.
// http://www.boost.org/LICENSE_1_0.txt

module ddmd.dstruct;

import core.stdc.stdio;
import ddmd.aggregate;
import ddmd.argtypes;
import ddmd.arraytypes;
import ddmd.gluelayer;
import ddmd.clone;
import ddmd.declaration;
import ddmd.dmodule;
import ddmd.doc;
import ddmd.dscope;
import ddmd.dsymbol;
import ddmd.dtemplate;
import ddmd.errors;
import ddmd.expression;
import ddmd.func;
import ddmd.globals;
import ddmd.hdrgen;
import ddmd.id;
import ddmd.identifier;
import ddmd.init;
import ddmd.mtype;
import ddmd.opover;
import ddmd.root.outbuffer;
import ddmd.statement;
import ddmd.tokens;
import ddmd.typinf;
import ddmd.visitor;

/***************************************
 * Search toString member function for TypeInfo_Struct.
 *      string toString();
 */
extern (C++) FuncDeclaration search_toString(StructDeclaration sd)
{
    Dsymbol s = search_function(sd, Id.tostring);
    FuncDeclaration fd = s ? s.isFuncDeclaration() : null;
    if (fd)
    {
        static __gshared TypeFunction tftostring;
        if (!tftostring)
        {
            tftostring = new TypeFunction(null, Type.tstring, 0, LINKd);
            tftostring = cast(TypeFunction)tftostring.merge();
        }
        fd = fd.overloadExactMatch(tftostring);
    }
    return fd;
}

/***************************************
 * Request additonal semantic analysis for TypeInfo generation.
 */
extern (C++) void semanticTypeInfo(Scope* sc, Type t)
{
    extern (C++) final class FullTypeInfoVisitor : Visitor
    {
        alias visit = super.visit;
    public:
        Scope* sc;

        override void visit(Type t)
        {
            Type tb = t.toBasetype();
            if (tb != t)
                tb.accept(this);
        }

        override void visit(TypeNext t)
        {
            if (t.next)
                t.next.accept(this);
        }

        override void visit(TypeBasic t)
        {
        }

        override void visit(TypeVector t)
        {
            t.basetype.accept(this);
        }

        override void visit(TypeAArray t)
        {
            t.index.accept(this);
            visit(cast(TypeNext)t);
        }

        override void visit(TypeFunction t)
        {
            visit(cast(TypeNext)t);
            // Currently TypeInfo_Function doesn't store parameter types.
        }

        override void visit(TypeStruct t)
        {
            StructDeclaration sd = t.sym;

            /* Step 1: create TypeInfoDeclaration
             */
            if (!sc) // inline may request TypeInfo.
            {
                Scope scx;
                scx._module = sd.getModule();
                getTypeInfoType(t, &scx);
                sd.requestTypeInfo = true;
            }
            else if (!sc.minst)
            {
                // don't yet have to generate TypeInfo instance if
                // the typeid(T) expression exists in speculative scope.
            }
            else
            {
                getTypeInfoType(t, sc);
                sd.requestTypeInfo = true;

                // Bugzilla 15149, if the typeid operand type comes from a
                // result of auto function, it may be yet speculative.
                unSpeculative(sc, sd);
            }

            /* Step 2: If the TypeInfo generation requires sd.semantic3, run it later.
             * This should be done even if typeid(T) exists in speculative scope.
             * Because it may appear later in non-speculative scope.
             */
            if (!sd.members)
                return; // opaque struct
            if (!sd.xeq && !sd.xcmp && !sd.postblit && !sd.dtor && !sd.xhash && !search_toString(sd))
                return; // none of TypeInfo-specific members

            // If the struct is in a non-root module, run semantic3 to get
            // correct symbols for the member function.
            if (sd.semanticRun >= PASSsemantic3)
            {
                // semantic3 is already done
            }
            else if (TemplateInstance ti = sd.isInstantiated())
            {
                if (ti.minst && !ti.minst.isRoot())
                    Module.addDeferredSemantic3(sd);
            }
            else
            {
                if (sd.inNonRoot())
                {
                    //printf("deferred sem3 for TypeInfo - sd = %s, inNonRoot = %d\n", sd->toChars(), sd->inNonRoot());
                    Module.addDeferredSemantic3(sd);
                }
            }
        }

        override void visit(TypeClass t)
        {
        }

        override void visit(TypeTuple t)
        {
            if (t.arguments)
            {
                for (size_t i = 0; i < t.arguments.dim; i++)
                {
                    Type tprm = (*t.arguments)[i].type;
                    if (tprm)
                        tprm.accept(this);
                }
            }
        }
    }

    if (sc)
    {
        if (!sc.func)
            return;
        if (sc.intypeof)
            return;
        if (sc.flags & (SCOPEctfe | SCOPEcompile))
            return;
    }

    scope FullTypeInfoVisitor v = new FullTypeInfoVisitor();
    v.sc = sc;
    t.accept(v);
}

struct StructFlags
{
    alias Type = uint;

    enum Enum : int
    {
        hasPointers = 0x1, // NB: should use noPointers as in ClassFlags
    }

    alias hasPointers = Enum.hasPointers;
}

enum StructPOD : int
{
    ISPODno,    // struct is not POD
    ISPODyes,   // struct is POD
    ISPODfwd,   // POD not yet computed
}

alias ISPODno = StructPOD.ISPODno;
alias ISPODyes = StructPOD.ISPODyes;
alias ISPODfwd = StructPOD.ISPODfwd;

/***********************************************************
 */
extern (C++) class StructDeclaration : AggregateDeclaration
{
public:
    int zeroInit;               // !=0 if initialize with 0 fill
    bool hasIdentityAssign;     // true if has identity opAssign
    bool hasIdentityEquals;     // true if has identity opEquals
    FuncDeclarations postblits; // Array of postblit functions
    FuncDeclaration postblit;   // aggregate postblit

    FuncDeclaration xeq;        // TypeInfo_Struct.xopEquals
    FuncDeclaration xcmp;       // TypeInfo_Struct.xopCmp
    FuncDeclaration xhash;      // TypeInfo_Struct.xtoHash
    extern (C++) static __gshared FuncDeclaration xerreq;   // object.xopEquals
    extern (C++) static __gshared FuncDeclaration xerrcmp;  // object.xopCmp

    structalign_t alignment;    // alignment applied outside of the struct
    StructPOD ispod;            // if struct is POD

    // For 64 bit Efl function call/return ABI
    Type arg1type;
    Type arg2type;

    // Even if struct is defined as non-root symbol, some built-in operations
    // (e.g. TypeidExp, NewExp, ArrayLiteralExp, etc) request its TypeInfo.
    // For those, today TypeInfo_Struct is generated in COMDAT.
    bool requestTypeInfo;

    final extern (D) this(Loc loc, Identifier id)
    {
        super(loc, id);
        zeroInit = 0; // assume false until we do semantic processing
        ispod = ISPODfwd;
        // For forward references
        type = new TypeStruct(this);
        if (id == Id.ModuleInfo && !Module.moduleinfo)
            Module.moduleinfo = this;
    }

    override Dsymbol syntaxCopy(Dsymbol s)
    {
        StructDeclaration sd =
            s ? cast(StructDeclaration)s
              : new StructDeclaration(loc, ident);
        return ScopeDsymbol.syntaxCopy(sd);
    }

    override final void semantic(Scope* sc)
    {
        //printf("StructDeclaration::semantic(this=%p, %s '%s', sizeok = %d)\n", this, parent.toChars(), toChars(), sizeok);

        //static int count; if (++count == 20) assert(0);

        if (semanticRun >= PASSsemanticdone)
            return;
        uint dprogress_save = Module.dprogress;
        int errors = global.errors;

        //printf("+StructDeclaration::semantic(this=%p, %s '%s', sizeok = %d)\n", this, parent.toChars(), toChars(), sizeok);
        Scope* scx = null;
        if (_scope)
        {
            sc = _scope;
            scx = _scope; // save so we don't make redundant copies
            _scope = null;
        }

        if (!parent)
        {
            assert(sc.parent && sc.func);
            parent = sc.parent;
        }
        assert(parent && !isAnonymous());

        if (this.errors)
            type = Type.terror;
        type = type.semantic(loc, sc);
        if (type.ty == Tstruct && (cast(TypeStruct)type).sym != this)
        {
            TemplateInstance ti = (cast(TypeStruct)type).sym.isInstantiated();
            if (ti && isError(ti))
                (cast(TypeStruct)type).sym = this;
        }

        // Ungag errors when not speculative
        Ungag ungag = ungagSpeculative();

        if (semanticRun == PASSinit)
        {
            protection = sc.protection;

            alignment = sc.structalign;

            storage_class |= sc.stc;
            if (storage_class & STCdeprecated)
                isdeprecated = true;
            if (storage_class & STCabstract)
                error("structs, unions cannot be abstract");

            userAttribDecl = sc.userAttribDecl;
        }
        else if (symtab && !scx)
        {
            semanticRun = PASSsemanticdone;
            return;
        }
        semanticRun = PASSsemantic;

        if (!members) // if opaque declaration
        {
            semanticRun = PASSsemanticdone;
            return;
        }
        if (!symtab)
            symtab = new DsymbolTable();

        if (sizeok == SIZEOKnone) // if not already done the addMember step
        {
            for (size_t i = 0; i < members.dim; i++)
            {
                Dsymbol s = (*members)[i];
                //printf("adding member '%s' to '%s'\n", s->toChars(), this->toChars());
                s.addMember(sc, this);
            }
        }

        Scope* sc2 = sc.push(this);
        sc2.stc &= STCsafe | STCtrusted | STCsystem;
        sc2.parent = this;
        if (isUnionDeclaration())
            sc2.inunion = 1;
        sc2.protection = Prot(PROTpublic);
        sc2.explicitProtection = 0;
        sc2.structalign = STRUCTALIGN_DEFAULT;
        sc2.userAttribDecl = null;

        if (sizeok == SIZEOKdone)
            goto LafterSizeok;
        sizeok = SIZEOKnone;

        /* Set scope so if there are forward references, we still might be able to
         * resolve individual members like enums.
         */
        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            //printf("struct: setScope %s %s\n", s->kind(), s->toChars());
            s.setScope(sc2);
        }

        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            s.importAll(sc2);
        }

        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            s.semantic(sc2);
        }

        finalizeSize(sc2);

        if (sizeok == SIZEOKfwd)
        {
            // semantic() failed because of forward references.
            // Unwind what we did, and defer it for later
            for (size_t i = 0; i < fields.dim; i++)
            {
                VarDeclaration v = fields[i];
                v.offset = 0;
            }
            fields.setDim(0);
            structsize = 0;
            alignsize = 0;

            sc2.pop();

            _scope = scx ? scx : sc.copy();
            _scope.setNoFree();
            _scope._module.addDeferredSemantic(this);
            Module.dprogress = dprogress_save;
            //printf("\tdeferring %s\n", toChars());
            return;
        }

        Module.dprogress++;
        //printf("-StructDeclaration::semantic(this=%p, '%s')\n", this, toChars());

    LafterSizeok:
        // The additions of special member functions should have its own
        // sub-semantic analysis pass, and have to be deferred sometimes.
        // See the case in compilable/test14838.d
        for (size_t i = 0; i < fields.dim; i++)
        {
            VarDeclaration v = fields[i];
            Type tb = v.type.baseElemOf();
            if (tb.ty != Tstruct)
                continue;
            StructDeclaration sd = (cast(TypeStruct)tb).sym;
            if (sd.semanticRun >= PASSsemanticdone)
                continue;

            sc2.pop();

            _scope = scx ? scx : sc.copy();
            _scope.setNoFree();
            _scope._module.addDeferredSemantic(this);
            //printf("\tdeferring %s\n", toChars());
            return;
        }

        /* Look for special member functions.
         */
        aggNew = cast(NewDeclaration)search(Loc(), Id.classNew);
        aggDelete = cast(DeleteDeclaration)search(Loc(), Id.classDelete);

        // this->ctor is already set in finalizeSize()

        dtor = buildDtor(this, sc2);
        postblit = buildPostBlit(this, sc2);

        buildOpAssign(this, sc2);
        buildOpEquals(this, sc2);

        xeq = buildXopEquals(this, sc2);
        xcmp = buildXopCmp(this, sc2);
        xhash = buildXtoHash(this, sc2);

        /* Even if the struct is merely imported and its semantic3 is not run,
         * the TypeInfo object would be speculatively stored in each object
         * files. To set correct function pointer, run semantic3 for xeq and xcmp.
         */
        //if ((xeq && xeq != xerreq || xcmp && xcmp != xerrcmp) && isImportedSym(this))
        //    Module::addDeferredSemantic3(this);

        /* Defer requesting semantic3 until TypeInfo generation is actually invoked.
         * See semanticTypeInfo().
         */
        inv = buildInv(this, sc2);

        sc2.pop();

        if (ctor)
        {
            Dsymbol scall = search(Loc(), Id.call);
            if (scall)
            {
                uint xerrors = global.startGagging();
                sc = sc.push();
                sc.tinst = null;
                sc.minst = null;
                FuncDeclaration fcall = resolveFuncCall(loc, sc, scall, null, null, null, 1);
                sc = sc.pop();
                global.endGagging(xerrors);

                if (fcall && fcall.isStatic())
                {
                    error(fcall.loc, "static opCall is hidden by constructors and can never be called");
                    errorSupplemental(fcall.loc, "Please use a factory method instead, or replace all constructors with static opCall.");
                }
            }
        }

        Module.dprogress++;
        semanticRun = PASSsemanticdone;

        TypeTuple tup = toArgTypes(type);
        size_t dim = tup.arguments.dim;
        if (dim >= 1)
        {
            assert(dim <= 2);
            arg1type = (*tup.arguments)[0].type;
            if (dim == 2)
                arg2type = (*tup.arguments)[1].type;
        }

        if (sc.func)
            semantic2(sc);

        if (global.errors != errors)
        {
            // The type is no good.
            type = Type.terror;
            this.errors = true;
            if (deferred)
                deferred.errors = true;
        }

        if (deferred && !global.gag)
        {
            deferred.semantic2(sc);
            deferred.semantic3(sc);
        }

        version (none)
        {
            if (type.ty == Tstruct && (cast(TypeStruct)type).sym != this)
            {
                printf("this = %p %s\n", this, this.toChars());
                printf("type = %d sym = %p\n", type.ty, (cast(TypeStruct)type).sym);
            }
        }
        assert(type.ty != Tstruct || (cast(TypeStruct)type).sym == this);
    }

    final void semanticTypeInfoMembers()
    {
        if (xeq &&
            xeq._scope &&
            xeq.semanticRun < PASSsemantic3done)
        {
            uint errors = global.startGagging();
            xeq.semantic3(xeq._scope);
            if (global.endGagging(errors))
                xeq = xerreq;
        }

        if (xcmp &&
            xcmp._scope &&
            xcmp.semanticRun < PASSsemantic3done)
        {
            uint errors = global.startGagging();
            xcmp.semantic3(xcmp._scope);
            if (global.endGagging(errors))
                xcmp = xerrcmp;
        }

        FuncDeclaration ftostr = search_toString(this);
        if (ftostr &&
            ftostr._scope &&
            ftostr.semanticRun < PASSsemantic3done)
        {
            ftostr.semantic3(ftostr._scope);
        }

        if (xhash &&
            xhash._scope &&
            xhash.semanticRun < PASSsemantic3done)
        {
            xhash.semantic3(xhash._scope);
        }

        if (postblit &&
            postblit._scope &&
            postblit.semanticRun < PASSsemantic3done)
        {
            postblit.semantic3(postblit._scope);
        }

        if (dtor &&
            dtor._scope &&
            dtor.semanticRun < PASSsemantic3done)
        {
            dtor.semantic3(dtor._scope);
        }
    }

    override final Dsymbol search(Loc loc, Identifier ident, int flags = IgnoreNone)
    {
        //printf("%s.StructDeclaration::search('%s')\n", toChars(), ident->toChars());
        if (_scope && !symtab)
            semantic(_scope);

        if (!members || !symtab) // opaque or semantic() is not yet called
        {
            error("is forward referenced when looking for '%s'", ident.toChars());
            return null;
        }

        return ScopeDsymbol.search(loc, ident, flags);
    }

    override const(char)* kind()
    {
        return "struct";
    }

    override final void finalizeSize(Scope* sc)
    {
        //printf("StructDeclaration::finalizeSize() %s\n", toChars());
        if (sizeok != SIZEOKnone)
            return;

        // Set the offsets of the fields and determine the size of the struct
        uint offset = 0;
        bool isunion = isUnionDeclaration() !is null;
        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            s.setFieldOffset(this, &offset, isunion);
        }
        if (sizeok == SIZEOKfwd)
            return;

        // 0 sized struct's are set to 1 byte
        if (structsize == 0)
        {
            structsize = 1;
            alignsize = 1;
        }

        // Round struct size up to next alignsize boundary.
        // This will ensure that arrays of structs will get their internals
        // aligned properly.
        if (alignment == STRUCTALIGN_DEFAULT)
            structsize = (structsize + alignsize - 1) & ~(alignsize - 1);
        else
            structsize = (structsize + alignment - 1) & ~(alignment - 1);
        sizeok = SIZEOKdone;

        // Calculate fields[i].overlapped
        checkOverlappedFields();

        // Determine if struct is all zeros or not
        zeroInit = 1;
        for (size_t i = 0; i < fields.dim; i++)
        {
            VarDeclaration vd = fields[i];
            if (!vd.isDataseg())
            {
                if (vd._init)
                {
                    // Should examine init to see if it is really all 0's
                    zeroInit = 0;
                    break;
                }
                else
                {
                    if (!vd.type.isZeroInit(loc))
                    {
                        zeroInit = 0;
                        break;
                    }
                }
            }
        }

        // Look for the constructor, for the struct literal/constructor call expression
        ctor = searchCtor();
        if (ctor)
        {
            // Finish all constructors semantics to determine this->noDefaultCtor.
            struct SearchCtor
            {
                extern (C++) static int fp(Dsymbol s, void* ctxt)
                {
                    CtorDeclaration f = s.isCtorDeclaration();
                    if (f && f.semanticRun == PASSinit)
                        f.semantic(null);
                    return 0;
                }
            }

            for (size_t i = 0; i < members.dim; i++)
            {
                Dsymbol s = (*members)[i];
                s.apply(&SearchCtor.fp, null);
            }
        }
    }

    /***************************************
     * Fit elements[] to the corresponding type of field[].
     * Input:
     *      loc
     *      sc
     *      elements    The explicit arguments that given to construct object.
     *      stype       The constructed object type.
     * Returns false if any errors occur.
     * Otherwise, returns true and elements[] are rewritten for the output.
     */
    final bool fit(Loc loc, Scope* sc, Expressions* elements, Type stype)
    {
        if (!elements)
            return true;

        size_t nfields = fields.dim - isNested();
        size_t offset = 0;
        for (size_t i = 0; i < elements.dim; i++)
        {
            Expression e = (*elements)[i];
            if (!e)
                continue;

            e = resolveProperties(sc, e);
            if (i >= nfields)
            {
                if (i == fields.dim - 1 && isNested() && e.op == TOKnull)
                {
                    // CTFE sometimes creates null as hidden pointer; we'll allow this.
                    continue;
                }
                .error(loc, "more initializers than fields (%d) of %s", nfields, toChars());
                return false;
            }
            VarDeclaration v = fields[i];
            if (v.offset < offset)
            {
                .error(loc, "overlapping initialization for %s", v.toChars());
                return false;
            }
            offset = cast(uint)(v.offset + v.type.size());

            Type t = v.type;
            if (stype)
                t = t.addMod(stype.mod);
            Type origType = t;
            Type tb = t.toBasetype();

            /* Look for case of initializing a static array with a too-short
             * string literal, such as:
             *  char[5] foo = "abc";
             * Allow this by doing an explicit cast, which will lengthen the string
             * literal.
             */
            if (e.op == TOKstring && tb.ty == Tsarray)
            {
                StringExp se = cast(StringExp)e;
                Type typeb = se.type.toBasetype();
                TY tynto = tb.nextOf().ty;
                if (!se.committed &&
                    (typeb.ty == Tarray || typeb.ty == Tsarray) &&
                    (tynto == Tchar || tynto == Twchar || tynto == Tdchar) &&
                    se.numberOfCodeUnits(tynto) < (cast(TypeSArray)tb).dim.toInteger())
                {
                    e = se.castTo(sc, t);
                    goto L1;
                }
            }

            while (!e.implicitConvTo(t) && tb.ty == Tsarray)
            {
                /* Static array initialization, as in:
                 *  T[3][5] = e;
                 */
                t = tb.nextOf();
                tb = t.toBasetype();
            }
            if (!e.implicitConvTo(t))
                t = origType; // restore type for better diagnostic

            e = e.implicitCastTo(sc, t);
        L1:
            if (e.op == TOKerror)
                return false;

            (*elements)[i] = e.isLvalue() ? callCpCtor(sc, e) : valueNoDtor(e);
        }
        return true;
    }

    /***************************************
     * Return true if struct is POD (Plain Old Data).
     * This is defined as:
     *      not nested
     *      no postblits, destructors, or assignment operators
     *      no 'ref' fields or fields that are themselves non-POD
     * The idea being these are compatible with C structs.
     */
    final bool isPOD()
    {
        // If we've already determined whether this struct is POD.
        if (ispod != ISPODfwd)
            return (ispod == ISPODyes);

        ispod = ISPODyes;

        if (enclosing || postblit || dtor)
            ispod = ISPODno;

        // Recursively check all fields are POD.
        for (size_t i = 0; i < fields.dim; i++)
        {
            VarDeclaration v = fields[i];
            if (v.storage_class & STCref)
            {
                ispod = ISPODno;
                break;
            }

            Type tv = v.type.baseElemOf();
            if (tv.ty == Tstruct)
            {
                TypeStruct ts = cast(TypeStruct)tv;
                StructDeclaration sd = ts.sym;
                if (!sd.isPOD())
                {
                    ispod = ISPODno;
                    break;
                }
            }
        }

        return (ispod == ISPODyes);
    }

    override final StructDeclaration isStructDeclaration()
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }
}

/***********************************************************
 */
extern (C++) final class UnionDeclaration : StructDeclaration
{
public:
    extern (D) this(Loc loc, Identifier id)
    {
        super(loc, id);
    }

    override Dsymbol syntaxCopy(Dsymbol s)
    {
        assert(!s);
        auto ud = new UnionDeclaration(loc, ident);
        return StructDeclaration.syntaxCopy(ud);
    }

    override const(char)* kind()
    {
        return "union";
    }

    override UnionDeclaration isUnionDeclaration()
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }
}
