%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[SimplCore]{Driver for simplifying @Core@ programs}

\begin{code}
#include "HsVersions.h"

module SimplCore ( core2core ) where

IMP_Ubiq(){-uitous-}
IMPORT_1_3(IO(hPutStr,stderr))

import AnalFBWW		( analFBWW )
import Bag		( isEmptyBag, foldBag )
import BinderInfo	( BinderInfo{-instance Outputable-} )
import CmdLineOpts	( CoreToDo(..), SimplifierSwitch(..), switchIsOn,
			  opt_D_show_passes,
			  opt_D_simplifier_stats,
			  opt_D_dump_simpl,
			  opt_D_verbose_core2core,
			  opt_DoCoreLinting,
			  opt_FoldrBuildOn,
			  opt_ReportWhyUnfoldingsDisallowed,
			  opt_ShowImportSpecs,
			  opt_LiberateCaseThreshold
			)
import CoreLint		( lintCoreBindings )
import CoreSyn
import CoreUtils	( coreExprType )
import SimplUtils	( etaCoreExpr, typeOkForCase )
import CoreUnfold
import Literal		( Literal(..), literalType, mkMachInt )
import ErrUtils		( ghcExit, dumpIfSet, doIfSet )
import FiniteMap	( FiniteMap )
import FloatIn		( floatInwards )
import FloatOut		( floatOutwards )
import FoldrBuildWW	( mkFoldrBuildWW )
import Id		( mkSysLocal, setIdVisibility, replaceIdInfo, 
                          replacePragmaInfo, getIdDemandInfo, idType,
			  getIdInfo, getPragmaInfo, mkIdWithNewUniq,
			  nullIdEnv, addOneToIdEnv, delOneFromIdEnv,
 			  lookupIdEnv, SYN_IE(IdEnv), omitIfaceSigForId,
			  apply_to_Id,
			  GenId{-instance Outputable-}, SYN_IE(Id)
			)
import IdInfo		( willBeDemanded, DemandInfo )
import Name		( isExported, isLocallyDefined, 
			  isLocalName, uniqToOccName,
			  SYN_IE(Module), NamedThing(..), OccName(..)
			)
import TyCon		( TyCon )
import PrimOp		( PrimOp(..) )
import PrelVals		( unpackCStringId, unpackCString2Id,
			  integerZeroId, integerPlusOneId,
			  integerPlusTwoId, integerMinusOneId
			)
import Type		( maybeAppDataTyCon, isPrimType, SYN_IE(Type) )
import TysWiredIn	( stringTy, isIntegerTy )
import LiberateCase	( liberateCase )
import MagicUFs		( MagicUnfoldingFun )
import Outputable	( pprDumpStyle, printErrs,
			  PprStyle(..), Outputable(..){-instance * (,) -}
			)
import PprCore
import PprType		( GenType{-instance Outputable-}, GenTyVar{-ditto-},
			  nmbrType
			)
import Pretty		( Doc, vcat, ($$), hsep )
import SAT		( doStaticArgs )
import SimplMonad	( zeroSimplCount, showSimplCount, SimplCount )
import SimplPgm		( simplifyPgm )
import Specialise
import SpecUtils	( pprSpecErrs )
import StrictAnal	( saWwTopBinds )
import TyVar		( SYN_IE(TyVar), nullTyVarEnv, GenTyVar{-instance Eq-},
			  nameTyVar
		        )
import Unique		( Unique{-instance Eq-}, Uniquable(..),
			  integerTyConKey, ratioTyConKey,
			  mkUnique, incrUnique,
			  initTidyUniques
		        )
import UniqSupply	( UniqSupply, mkSplitUniqSupply, 
                          splitUniqSupply, getUnique
		        )
import UniqFM           ( UniqFM, lookupUFM, addToUFM )
import Usage            ( SYN_IE(UVar), cloneUVar )
import Util		( mapAccumL, assertPanic, panic{-ToDo:rm-}, pprTrace, pprPanic )
import SrcLoc		( noSrcLoc )
import Constants	( tARGET_MIN_INT, tARGET_MAX_INT )
import Bag
import Maybes

\end{code}

\begin{code}
core2core :: [CoreToDo]			-- spec of what core-to-core passes to do
	  -> FAST_STRING		-- module name (profiling only)
	  -> UniqSupply		-- a name supply
	  -> [TyCon]			-- local data tycons and tycon specialisations
	  -> FiniteMap TyCon [(Bool, [Maybe Type])]
	  -> [CoreBinding]		-- input...
	  -> IO
	      ([CoreBinding],		-- results: program, plus...
	      SpecialiseData)		--  specialisation data

core2core core_todos module_name us local_tycons tycon_specs binds
  = 	-- Do the main business
     foldl_mn do_core_pass
		(binds, us, init_specdata, zeroSimplCount)
		core_todos
		>>= \ (processed_binds, us', spec_data, simpl_stats) ->

	-- Do the final tidy-up
     let
	final_binds = tidyCorePgm module_name processed_binds
     in
     lintCoreBindings "TidyCorePgm" True final_binds	>>


	-- Dump output
     dumpIfSet (opt_D_dump_simpl || opt_D_verbose_core2core)
	"Core transformations" 
	(pprCoreBindings pprDumpStyle final_binds)			>>

	-- Report statistics
     doIfSet opt_D_simplifier_stats
	 (hPutStr stderr ("\nSimplifier Stats:\n")	>>
	  hPutStr stderr (showSimplCount simpl_stats)	>>
	  hPutStr stderr "\n")					>>

	-- Return results
    return (final_binds, spec_data)
  where
    init_specdata = initSpecData local_tycons tycon_specs

    --------------
    do_core_pass info@(binds, us, spec_data, simpl_stats) to_do =
     case (splitUniqSupply us) of 
      (us1,us2) ->
    	case to_do of
	  CoreDoSimplify simpl_sw_chkr
	    -> _scc_ "CoreSimplify"
	       begin_pass ("Simplify" ++ if switchIsOn simpl_sw_chkr SimplDoFoldrBuild
					 then " (foldr/build)" else "") >>
	       case (simplifyPgm binds simpl_sw_chkr simpl_stats us1) of
		 (p, it_cnt, simpl_stats2)
		   -> end_pass us2 p spec_data simpl_stats2
			       ("Simplify (" ++ show it_cnt ++ ")"
				 ++ if switchIsOn simpl_sw_chkr SimplDoFoldrBuild
				    then " foldr/build" else "")

	  CoreDoFoldrBuildWorkerWrapper
	    -> _scc_ "CoreDoFoldrBuildWorkerWrapper"
	       begin_pass "FBWW" >>
	       case (mkFoldrBuildWW us1 binds) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "FBWW" }

	  CoreDoFoldrBuildWWAnal
	    -> _scc_ "CoreDoFoldrBuildWWAnal"
	       begin_pass "AnalFBWW" >>
	       case (analFBWW binds) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "AnalFBWW" }

	  CoreLiberateCase
	    -> _scc_ "LiberateCase"
	       begin_pass "LiberateCase" >>
	       case (liberateCase opt_LiberateCaseThreshold binds) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "LiberateCase" }

	  CoreDoFloatInwards
	    -> _scc_ "FloatInwards"
	       begin_pass "FloatIn" >>
	       case (floatInwards binds) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "FloatIn" }

	  CoreDoFullLaziness
	    -> _scc_ "CoreFloating"
	       begin_pass "FloatOut" >>
	       case (floatOutwards us1 binds) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "FloatOut" }

	  CoreDoStaticArgs
	    -> _scc_ "CoreStaticArgs"
	       begin_pass "StaticArgs" >>
	       case (doStaticArgs binds us1) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "StaticArgs" }
		-- Binds really should be dependency-analysed for static-
		-- arg transformation... Not to worry, they probably are.
		-- (I don't think it *dies* if they aren't [WDP 94/04/15])

	  CoreDoStrictness
	    -> _scc_ "CoreStranal"
	       begin_pass "StrAnal" >>
	       case (saWwTopBinds us1 binds) of { binds2 ->
	       end_pass us2 binds2 spec_data simpl_stats "StrAnal" }

	  CoreDoSpecialising
	    -> _scc_ "Specialise"
	       begin_pass "Specialise" >>
	       case (specProgram us1 binds spec_data) of {
		 (p, spec_data2@(SpecData _ spec_noerrs _ _ _
					  spec_errs spec_warn spec_tyerrs)) ->

		   -- if we got errors, we die straight away
		   doIfSet ((not spec_noerrs) ||
			    (opt_ShowImportSpecs && not (isEmptyBag spec_warn)))
			(printErrs
			    (pprSpecErrs module_name spec_errs spec_warn spec_tyerrs))
								>>

		   doIfSet (not spec_noerrs) -- Stop here if specialisation errors occured
			   (ghcExit 1)				>>

		   end_pass us2 p spec_data2 simpl_stats "Specialise"
	       }

	  CoreDoPrintCore	-- print result of last pass
	    -> dumpIfSet (not opt_D_verbose_core2core) "Print Core"
	 	  (pprCoreBindings pprDumpStyle binds)	>>
	       return (binds, us1, spec_data, simpl_stats)

    -------------------------------------------------

    begin_pass what
      = if opt_D_show_passes
	then hPutStr stderr ("*** Core2Core: "++what++"\n")
	else return ()

    end_pass us2 binds2
	     spec_data2@(SpecData spec_done _ _ _ _ _ _ _)
	     simpl_stats2 what
      = -- Report verbosely, if required
	dumpIfSet opt_D_verbose_core2core what
	    (pprCoreBindings pprDumpStyle binds2)		>>

	lintCoreBindings what spec_done binds2		>>

	return
	  (binds2,	-- processed binds, possibly run thru CoreLint
	   us2,		-- UniqSupply for the next guy
	   spec_data2,	-- possibly-updated specialisation info
	   simpl_stats2	-- accumulated simplifier stats
	  )


-- here so it can be inlined...
foldl_mn f z []     = return z
foldl_mn f z (x:xs) = f z x	>>= \ zz ->
		      foldl_mn f zz xs
\end{code}



%************************************************************************
%*									*
\subsection[SimplCore-indirections]{Eliminating indirections in Core code, and globalising}
%*									*
%************************************************************************

Several tasks are done by @tidyCorePgm@

1.  Eliminate indirections.  The point here is to transform
	x_local = E
	x_exported = x_local
    ==>
	x_exported = E

2.  Make certain top-level bindings into Globals. The point is that 
    Global things get externally-visible labels at code generation
    time

3.  Make the representation of NoRep literals explicit, and
    float their bindings to the top level

4.  Convert
	case x of {...; x' -> ...x'...}
    ==>
	case x of {...; _  -> ...x... }
    See notes in SimplCase.lhs, near simplDefault for the reasoning here.

5.  *Mangle* cases involving fork# and par# in the discriminant.  The
    original templates for these primops (see @PrelVals.lhs@) constructed
    case expressions with boolean results solely to fool the strictness
    analyzer, the simplifier, and anyone else who might want to fool with
    the evaluation order.  At this point in the compiler our evaluation
    order is safe.  Therefore, we convert expressions of the form:

    	case par# e of
    	  True -> rhs
    	  False -> parError#
    ==>
    	case par# e of
    	  _ -> rhs

6.	Eliminate polymorphic case expressions.  We can't generate code for them yet.

7.	Do eta reduction for lambda abstractions appearing in:
		- the RHS of case alternatives
		- the body of a let
	These will otherwise turn into local bindings during Core->STG; better to
	nuke them if possible.   (In general the simplifier does eta expansion not
	eta reduction, up to this point.)

8.	Do let-to-case.  See notes in Simplify.lhs for why we defer let-to-case
	for multi-constructor types.

9.	Give all binders a nice print-name.  Their uniques aren't changed; rather we give
	them lexically unique occ-names, so that we can safely print the OccNae only
	in the interface file.  [Bad idea to change the uniques, because the code
	generator makes global labels from the uniques for local thunks etc.]


Eliminate indirections
~~~~~~~~~~~~~~~~~~~~~~
In @elimIndirections@, we look for things at the top-level of the form...
\begin{verbatim}
	x_local = ....
	x_exported = x_local
\end{verbatim}
In cases we find like this, we go {\em backwards} and replace
\tr{x_local} with \tr{x_exported}.  This save a gratuitous jump
(from \tr{x_exported} to \tr{x_local}), and makes strictness
information propagate better.

We rely on prior eta reduction to simplify things like
\begin{verbatim}
	x_exported = /\ tyvars -> x_local tyvars
==>
	x_exported = x_local
\end{verbatim}

If more than one exported thing is equal to a local thing (i.e., the
local thing really is shared), then we do one only:
\begin{verbatim}
	x_local = ....
	x_exported1 = x_local
	x_exported2 = x_local
==>
	x_exported1 = ....

	x_exported2 = x_exported1
\end{verbatim}

There's a possibility of leaving unchanged something like this:
\begin{verbatim}
	x_local = ....
	x_exported1 = x_local Int
\end{verbatim}
By the time we've thrown away the types in STG land this 
could be eliminated.  But I don't think it's very common
and it's dangerous to do this fiddling in STG land 
because we might elminate a binding that's mentioned in the
unfolding for something.

General Strategy: first collect the info; then make a \tr{Id -> Id} mapping.
Then blast the whole program (LHSs as well as RHSs) with it.



\begin{code}
tidyCorePgm :: Module -> [CoreBinding] -> [CoreBinding]

tidyCorePgm mod binds_in
  = initTM mod indirection_env $
    tidyTopBindings (catMaybes reduced_binds)	`thenTM` \ binds ->
    returnTM (bagToList binds)
  where
    (indirection_env, reduced_binds) = mapAccumL try_bind nullIdEnv binds_in

    try_bind :: IdEnv CoreBinder -> CoreBinding -> (IdEnv CoreBinder, Maybe CoreBinding)
    try_bind env_so_far (NonRec exported_binder rhs)
	| isExported exported_binder &&		-- Only if this is exported
	  maybeToBool maybe_rhs_id &&		-- 	and the RHS is a simple Id

	  isLocallyDefined rhs_id &&		-- Only if this one is defined in this
	  					-- 	module, so that we *can* change its
					  	-- 	binding to be the exported thing!

	  not (isExported rhs_id) &&		-- Only if this one is not itself exported,
						--	since the transformation will nuke it

	  not (omitIfaceSigForId rhs_id) &&	-- Don't do the transformation if rhs_id is
						-- 	something like a constructor, whose 
						--	definition is implicitly exported and 
						-- 	which must not vanish.
		-- To illustrate the preceding check consider
		--	data T = MkT Int
		--	mkT = MkT
		--	f x = MkT (x+1)
		-- Here, we'll make a local, non-exported, defn for MkT, and without the
		-- above condition we'll transform it to:
		--	mkT = \x. MkT [x]
		--	f = \y. mkT (y+1)
		-- This is bad because mkT will get the IdDetails of MkT, and won't
		-- be exported.  Also the code generator won't make a definition for
		-- the MkT constructor.
		-- Slightly gruesome, this.

	  not (maybeToBool (lookupIdEnv env_so_far rhs_id))
						-- Only if not already substituted for

	= (addOneToIdEnv env_so_far rhs_id (ValBinder new_rhs_id), Nothing)
	where
	   maybe_rhs_id = case etaCoreExpr rhs of
				Var rhs_id -> Just rhs_id
				other	   -> Nothing
	   Just rhs_id  = maybe_rhs_id
	   new_rhs_id   = exported_binder `replaceIdInfo`     getIdInfo rhs_id
					  `replacePragmaInfo` getPragmaInfo rhs_id
				-- NB: we keep the Pragmas and IdInfo for the old rhs_id!
				-- This is important; it might be marked "no-inline" by
				-- the occurrence analyser (because it's recursive), and
				-- we must not lose that information.

    try_bind env_so_far bind
	= (env_so_far, Just bind)
\end{code}

Top level bindings
~~~~~~~~~~~~~~~~~~
\begin{code}
tidyTopBindings [] = returnTM emptyBag
tidyTopBindings (b:bs)
  = tidyTopBinding  b		$
    tidyTopBindings bs

tidyTopBinding :: CoreBinding
	       -> TopTidyM (Bag CoreBinding)
	       -> TopTidyM (Bag CoreBinding)

tidyTopBinding (NonRec bndr rhs) thing_inside
  = initNestedTM (tidyCoreExpr rhs)		`thenTM` \ (rhs',floats) ->
    mungeTopBinder bndr				$ \ bndr' ->
    thing_inside 				`thenTM` \ binds ->
    returnTM ((floats `snocBag` NonRec bndr' rhs') `unionBags` binds)

tidyTopBinding (Rec pairs) thing_inside
  = mungeTopBinders binders			$ \ binders' ->
    initNestedTM (mapTM tidyCoreExpr rhss)	`thenTM` \ (rhss', floats) ->
    thing_inside				`thenTM` \ binds_inside ->
    returnTM ((floats `snocBag` Rec (binders' `zip` rhss')) `unionBags` binds_inside)
  where
    (binders, rhss) = unzip pairs
\end{code}



Expressions
~~~~~~~~~~~
\begin{code}
tidyCoreExpr (Var v) = lookupId v	`thenTM` \ v' ->
		       returnTM (Var v')

tidyCoreExpr (Lit lit)
  = litToRep lit	`thenTM` \ (_, lit_expr) ->
    returnTM lit_expr

tidyCoreExpr (App fun arg)
  = tidyCoreExpr fun	`thenTM` \ fun' ->
    tidyCoreArg arg	`thenTM` \ arg' ->
    returnTM (App fun' arg')

tidyCoreExpr (Con con args)
  = mapTM tidyCoreArg args	`thenTM` \ args' ->
    returnTM (Con con args')

tidyCoreExpr (Prim prim args)
  = tidyPrimOp prim		`thenTM` \ prim' ->
    mapTM tidyCoreArg args	`thenTM` \ args' ->
    returnTM (Prim prim' args')

tidyCoreExpr (Lam (ValBinder v) body)
  = newId v			$ \ v' ->
    tidyCoreExpr body		`thenTM` \ body' ->
    returnTM (Lam (ValBinder v') body')

tidyCoreExpr (Lam (TyBinder tv) body)
  = newTyVar tv			$ \ tv' ->
    tidyCoreExpr body		`thenTM` \ body' ->
    returnTM (Lam (TyBinder tv') body')

tidyCoreExpr (Lam (UsageBinder uv) body)
  = newUVar uv			$ \ uv' ->
    tidyCoreExpr body		`thenTM` \ body' ->
    returnTM (Lam (UsageBinder uv') body')

	-- Try for let-to-case (see notes in Simplify.lhs for why
	-- some let-to-case stuff is deferred to now).
tidyCoreExpr (Let (NonRec bndr rhs) body)
  | willBeDemanded (getIdDemandInfo bndr) && 
    not rhs_is_whnf &&		-- Don't do it if RHS is already in WHNF
    typeOkForCase (idType bndr)
  = ASSERT( not (isPrimType (idType bndr)) )
    tidyCoreExpr (Case rhs (AlgAlts [] (BindDefault bndr body)))
  where
    rhs_is_whnf = case mkFormSummary rhs of
			VarForm -> True
			ValueForm -> True
			other -> False

tidyCoreExpr (Let (NonRec bndr rhs) body)
  = tidyCoreExpr rhs		`thenTM` \ rhs' ->
    newId bndr			$ \ bndr' ->
    tidyCoreExprEta body	`thenTM` \ body' ->
    returnTM (Let (NonRec bndr' rhs') body')

tidyCoreExpr (Let (Rec pairs) body)
  = newIds bndrs		$ \ bndrs' ->
    mapTM tidyCoreExpr rhss	`thenTM` \ rhss' ->
    tidyCoreExprEta body	`thenTM` \ body' ->
    returnTM (Let (Rec (bndrs' `zip` rhss')) body')
  where
    (bndrs, rhss) = unzip pairs

tidyCoreExpr (SCC cc body)
  = tidyCoreExprEta body	`thenTM` \ body' ->
    returnTM (SCC cc body')

tidyCoreExpr (Coerce coercion ty body)
  = tidyCoreExprEta body	`thenTM` \ body' ->
    tidyTy ty			`thenTM` \ ty' ->
    returnTM (Coerce coercion ty' body')

-- Wierd case for par, seq, fork etc. See notes above.
tidyCoreExpr (Case scrut@(Prim op args) (PrimAlts _ (BindDefault binder rhs)))
  | funnyParallelOp op
  = tidyCoreExpr scrut			`thenTM` \ scrut' ->
    newId binder			$ \ binder' ->
    tidyCoreExprEta rhs			`thenTM` \ rhs' ->
    returnTM (Case scrut' (PrimAlts [] (BindDefault binder' rhs')))

-- Eliminate polymorphic case, for which we can't generate code just yet
tidyCoreExpr (Case scrut (AlgAlts [] (BindDefault deflt_bndr rhs)))
  | not (typeOkForCase (idType deflt_bndr))
  = pprTrace "Warning: discarding polymorphic case:" (ppr PprDebug scrut) $
    case scrut of
	Var v -> lookupId v	`thenTM` \ v' ->
		 extendEnvTM deflt_bndr v' (tidyCoreExpr rhs)
	other -> tidyCoreExpr (Let (NonRec deflt_bndr scrut) rhs)
  
tidyCoreExpr (Case scrut alts)
  = tidyCoreExpr scrut			`thenTM` \ scrut' ->
    tidy_alts scrut' alts		`thenTM` \ alts' ->
    returnTM (Case scrut' alts')
  where
    tidy_alts scrut (AlgAlts alts deflt)
	= mapTM tidy_alg_alt alts	`thenTM` \ alts' ->
	  tidy_deflt scrut deflt	`thenTM` \ deflt' ->
	  returnTM (AlgAlts alts' deflt')

    tidy_alts scrut (PrimAlts alts deflt)
	= mapTM tidy_prim_alt alts	`thenTM` \ alts' ->
	  tidy_deflt scrut deflt	`thenTM` \ deflt' ->
	  returnTM (PrimAlts alts' deflt')

    tidy_alg_alt (con,bndrs,rhs) = newIds bndrs		$ \ bndrs' ->
				   tidyCoreExprEta rhs	`thenTM` \ rhs' ->
				   returnTM (con, bndrs', rhs')

    tidy_prim_alt (lit,rhs) = tidyCoreExprEta rhs	`thenTM` \ rhs' ->
			      returnTM (lit,rhs')

	-- We convert	case x of {...; x' -> ...x'...}
	--	to
	--		case x of {...; _  -> ...x... }
	--
	-- See notes in SimplCase.lhs, near simplDefault for the reasoning.
	-- It's quite easily done: simply extend the environment to bind the
	-- default binder to the scrutinee.

    tidy_deflt scrut NoDefault = returnTM NoDefault
    tidy_deflt scrut (BindDefault bndr rhs)
	= newId bndr				$ \ bndr' ->
	  extend_env (tidyCoreExprEta rhs)	`thenTM` \ rhs' ->
	  returnTM (BindDefault bndr' rhs')
	where
 	  extend_env = case scrut of
			    Var v -> extendEnvTM bndr v
			    other -> \x -> x

tidyCoreExprEta e = tidyCoreExpr e	`thenTM` \ e' ->
		    returnTM (etaCoreExpr e')
\end{code}

Arguments
~~~~~~~~~
\begin{code}
tidyCoreArg :: CoreArg -> NestTidyM CoreArg

tidyCoreArg (VarArg v)
  = lookupId v	`thenTM` \ v' ->
    returnTM (VarArg v')

tidyCoreArg (LitArg lit)
  = litToRep lit		`thenTM` \ (lit_ty, lit_expr) ->
    case lit_expr of
	Var v -> returnTM (VarArg v)
	Lit l -> returnTM (LitArg l)
	other -> addTopFloat lit_ty lit_expr	`thenTM` \ v ->
		 returnTM (VarArg v)

tidyCoreArg (TyArg ty)   = tidyTy ty 	`thenTM` \ ty' ->
			   returnTM (TyArg ty')
tidyCoreArg (UsageArg u) = returnTM (UsageArg u)
\end{code}

\begin{code}
tidyPrimOp (CCallOp fn casm gc tys ty)
  = mapTM tidyTy tys	`thenTM` \ tys' ->
    tidyTy ty		`thenTM` \ ty' ->
    returnTM (CCallOp fn casm gc tys' ty')

tidyPrimOp other_prim_op = returnTM other_prim_op
\end{code}    


%************************************************************************
%*									*
\subsection[coreToStg-lits]{Converting literals}
%*									*
%************************************************************************

Literals: the NoRep kind need to be de-no-rep'd.
We always replace them with a simple variable, and float a suitable
binding out to the top level.

\begin{code}
		     
litToRep :: Literal -> NestTidyM (Type, CoreExpr)

litToRep (NoRepStr s)
  = returnTM (stringTy, rhs)
  where
    rhs = if (any is_NUL (_UNPK_ s))

	  then	 -- Must cater for NULs in literal string
		mkGenApp (Var unpackCString2Id)
			 [LitArg (MachStr s),
		      	  LitArg (mkMachInt (toInteger (_LENGTH_ s)))]

	  else	-- No NULs in the string
		App (Var unpackCStringId) (LitArg (MachStr s))

    is_NUL c = c == '\0'
\end{code}

If an Integer is small enough (Haskell implementations must support
Ints in the range $[-2^29+1, 2^29-1]$), wrap it up in @int2Integer@;
otherwise, wrap with @litString2Integer@.

\begin{code}
litToRep (NoRepInteger i integer_ty)
  = returnTM (integer_ty, rhs)
  where
    rhs | i == 0    = Var integerZeroId	  -- Extremely convenient to look out for
  	| i == 1    = Var integerPlusOneId  -- a few very common Integer literals!
  	| i == 2    = Var integerPlusTwoId
  	| i == (-1) = Var integerMinusOneId
  
  	| i > tARGET_MIN_INT &&		-- Small enough, so start from an Int
	  i < tARGET_MAX_INT
	= Prim Int2IntegerOp [LitArg (mkMachInt i)]
  
  	| otherwise 			-- Big, so start from a string
	= Prim Addr2IntegerOp [LitArg (MachStr (_PK_ (show i)))]


litToRep (NoRepRational r rational_ty)
  = tidyCoreArg (LitArg (NoRepInteger (numerator   r) integer_ty))	`thenTM` \ num_arg ->
    tidyCoreArg (LitArg (NoRepInteger (denominator r) integer_ty))	`thenTM` \ denom_arg ->
    returnTM (rational_ty, Con ratio_data_con [TyArg integer_ty, num_arg, denom_arg])
  where
    (ratio_data_con, integer_ty)
      = case (maybeAppDataTyCon rational_ty) of
	  Just (tycon, [i_ty], [con])
	    -> ASSERT(isIntegerTy i_ty && uniqueOf tycon == ratioTyConKey)
	       (con, i_ty)

	  _ -> (panic "ratio_data_con", panic "integer_ty")

litToRep other_lit = returnTM (literalType other_lit, Lit other_lit)
\end{code}

\begin{code}
funnyParallelOp SeqOp  = True
funnyParallelOp ParOp  = True
funnyParallelOp ForkOp = True
funnyParallelOp _      = False
\end{code}  


%************************************************************************
%*									*
\subsection{The monad}
%*									*
%************************************************************************

\begin{code}
type TidyM a state =  Module
	     	      -> UniqFM CoreBinder		-- Maps Ids to Ids, TyVars to TyVars etc
		      -> state
		      -> (a, state)

type TopTidyM  a = TidyM a Unique
type NestTidyM a = TidyM a (Unique,	 		-- Global names
			    Unique,	 		-- Local names
			    Bag CoreBinding)		-- Floats


(initialTopTidyUnique, initialNestedTidyUnique) = initTidyUniques

initTM :: Module -> UniqFM CoreBinder -> TopTidyM a -> a
initTM mod env m
  = case m mod env initialTopTidyUnique of 
	(result, _) -> result

initNestedTM :: NestTidyM a -> TopTidyM (a, Bag CoreBinding)
initNestedTM m mod env global_us
  = case m mod env (global_us, initialNestedTidyUnique, emptyBag) of
	(result, (global_us', _, floats)) -> ((result, floats), global_us')

returnTM v mod env usf = (v, usf)
thenTM m k mod env usf = case m mod env usf of
			   (r, usf') -> k r mod env usf'

mapTM f []     = returnTM []
mapTM f (x:xs) = f x	`thenTM` \ r ->
		 mapTM f xs	`thenTM` \ rs ->
		 returnTM (r:rs)
\end{code}


\begin{code}
-- Need to extend the environment when we munge a binder, so that occurrences
-- of the binder will print the correct way (i.e. as a global not a local)
mungeTopBinder :: Id -> (Id -> TopTidyM a) -> TopTidyM a
mungeTopBinder id thing_inside mod env us
  = case lookupIdEnv env id of
	Just (ValBinder global) -> thing_inside global mod env us	-- Already bound

	other -> 	-- Give it a new print-name unless it's an exported thing
			-- setNameVisibility also does the local/global thing
		 let
			(id', us')  | isExported id = (id, us)
				    | otherwise
				    = (setIdVisibility (Just mod) us id, 
				       incrUnique us)

			new_env    = addToUFM env id (ValBinder id')
		 in
		 thing_inside id' mod new_env us'

mungeTopBinders []     k = k []
mungeTopBinders (b:bs) k = mungeTopBinder b	$ \ b' ->
			   mungeTopBinders bs	$ \ bs' ->
			   k (b' : bs')

addTopFloat :: Type -> CoreExpr -> NestTidyM Id
addTopFloat lit_ty lit_rhs mod env (gus, lus, floats)
  = let
        gus'      = incrUnique gus
        lit_local = mkSysLocal SLIT("lit") gus lit_ty noSrcLoc
        lit_id    = setIdVisibility (Just mod) gus lit_local
    in
    (lit_id, (gus', lus, floats `snocBag` NonRec lit_id lit_rhs))

lookupId :: Id -> TidyM Id state
lookupId v mod env usf
  = case lookupUFM env v of
	Nothing		    -> (v, usf)
	Just (ValBinder v') -> (v', usf)

extendEnvTM :: Id -> Id -> (TidyM a state) -> TidyM a state
extendEnvTM v v' m mod env usf
  = m mod (addOneToIdEnv env v (ValBinder v')) usf
\end{code}


Making new local binders
~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
newId id thing_inside mod env (gus, local_uniq, floats)
  = let 
	-- Give the Id a fresh print-name, *and* rename its type
	local_uniq'  = incrUnique local_uniq	
	rn_id        = setIdVisibility Nothing local_uniq id
	id'          = apply_to_Id (nmbr_ty env local_uniq') rn_id
	env'	     = addToUFM env id (ValBinder id')
    in
    thing_inside id' mod env' (gus, local_uniq', floats)

newIds [] thing_inside
  = thing_inside []
newIds (bndr:bndrs) thing_inside
  = newId bndr		$ \ bndr' ->
    newIds bndrs	$ \ bndrs' ->
    thing_inside (bndr' : bndrs')


newTyVar tyvar thing_inside mod env (gus, local_uniq, floats)
  = let
	local_uniq' = incrUnique local_uniq	
	tyvar'      = nameTyVar tyvar (uniqToOccName local_uniq)
	env'	    = addToUFM env tyvar (TyBinder tyvar')
    in
    thing_inside tyvar' mod env' (gus, local_uniq', floats)

newUVar uvar thing_inside mod env (gus, local_uniq, floats)
  = let
	local_uniq' = incrUnique local_uniq	
	uvar'       = cloneUVar uvar local_uniq
	env'	    = addToUFM env uvar (UsageBinder uvar')
    in
    thing_inside uvar' mod env' (gus, local_uniq', floats)
\end{code}

Re-numbering types
~~~~~~~~~~~~~~~~~~
\begin{code}
tidyTy ty mod env usf@(_, local_uniq, _)
  = (nmbr_ty env local_uniq ty, usf)
	-- We can use local_uniq as a base for renaming forall'd variables
	-- in the type; we don't need to know how many are consumed.

-- This little impedance-matcher calls nmbrType with the right arguments
nmbr_ty env uniq ty
  = nmbrType tv_env u_env uniq ty
  where
    tv_env :: TyVar -> TyVar
    tv_env tyvar = case lookupUFM env tyvar of
			Just (TyBinder tyvar') -> tyvar'
			other		       -> tyvar

    u_env :: UVar -> UVar
    u_env uvar = case lookupUFM env uvar of
			Just (UsageBinder uvar') -> uvar'
			other		         -> uvar
\end{code}


