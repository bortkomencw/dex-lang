-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE PatternSynonyms #-}

module Syntax (
    Type, Kind, BaseType (..), ScalarBaseType (..),
    Effect, EffectName (..), EffectRow (..),
    ClassName (..), TyQual (..), SrcPos, Var, Binder, Block (..), Decl (..),
    Expr (..), Atom (..), ArrowP (..), Arrow, PrimTC (..), Abs (..),
    PrimExpr (..), PrimCon (..), LitVal (..),
    PrimEffect (..), PrimOp (..), EffectSummary (..),
    PrimHof (..), LamExpr, PiType, WithSrc (..), srcPos, LetAnn (..),
    ScalarBinOp (..), ScalarUnOp (..), CmpOp (..), SourceBlock (..),
    ReachedEOF, SourceBlock' (..), SubstEnv, Scope, CmdName (..),
    Val, TopEnv, Op, Con, Hof, TC, Module (..), ImpFunction (..),
    ImpProg (..), ImpStatement, ImpInstr (..), IExpr (..), IVal, IPrimOp,
    IVar, IType (..), ArrayType, SetVal (..), MonMap (..), LitProg,
    ScalarTableType, ScalarTableVar, BinderInfo (..),Bindings,
    SrcCtx, Result (..), Output (..), OutFormat (..), DataFormat (..),
    Err (..), ErrType (..), Except, throw, throwIf, modifyErr, addContext,
    addSrcContext, catchIOExcept, liftEitherIO, (-->), (--@), (==>),
    sourceBlockBoundVars, uModuleBoundVars, PassName (..), bindingsAsVars,
    freeVars, freeUVars, HasVars, strToName, nameToStr, showPrimName,
    monMapSingle, monMapLookup, newEnv, Direction (..), ArrayRef, Array, Limit (..),
    UExpr, UExpr' (..), UType, UBinder, UPiBinder, UVar, declAsScope,
    UPat, UPat', PatP, PatP' (..), UModule (..), UDecl (..), UArrow, arrowEff,
    subst, deShadow, scopelessSubst, absArgType, applyAbs, makeAbs, freshSkolemVar,
    mkConsList, mkConsListTy, fromConsList, fromConsListTy, extendEffRow,
    scalarTableBaseType, varType, isTabTy, LogLevel (..), IRVariant (..),
    pattern IntLitExpr, pattern RealLitExpr,
    pattern IntVal, pattern UnitTy, pattern PairTy, pattern FunTy,
    pattern FixedIntRange, pattern RefTy, pattern BoolTy, pattern IntTy,
    pattern RealTy, pattern SumTy, pattern BaseTy, pattern UnitVal,
    pattern PairVal, pattern SumVal, pattern PureArrow, pattern ArrayVal,
    pattern RealVal, pattern BoolVal, pattern TyKind, pattern LamVal,
    pattern TabTy, pattern TabTyAbs, pattern TabVal, pattern TabValA,
    pattern Pure, pattern BinaryFunTy, pattern BinaryFunVal,
    pattern EffKind, pattern JArrayTy, pattern ArrayTy)
  where

import qualified Data.Map.Strict as M
import Control.Exception hiding (throw)
import Control.Monad.Fail
import Control.Monad.Identity
import Control.Monad.Writer
import Control.Monad.Except hiding (Except)
import qualified Data.Vector.Storable as V
import Data.Foldable (fold)
import Data.List (sort)
import Data.Store (Store)
import Data.Tuple (swap)
import GHC.Generics

import Cat
import Env
import Array

-- === core IR ===

data Atom = Var Var
          | Lam LamExpr
          | Pi  PiType
          | Con Con
          | TC  TC
          | Eff EffectRow
            deriving (Show, Eq, Generic)

data Expr = App Atom Atom
          | Atom Atom
          | Op  Op
          | Hof Hof
            deriving (Show, Eq, Generic)

data Decl  = Let LetAnn Binder Expr    deriving (Show, Eq, Generic)
data Block = Block [Decl] Expr  deriving (Show, Eq, Generic)

type Var    = VarP Type
type Binder = VarP Type

data Abs a = Abs Binder a  deriving (Show, Generic, Functor, Foldable, Traversable)
type LamExpr = Abs (Arrow, Block)
type PiType  = Abs (Arrow, Type)

type Arrow = ArrowP EffectRow
data ArrowP eff = PlainArrow eff
                | ImplicitArrow
                | ClassArrow
                | TabArrow
                | LinArrow
                  deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data LetAnn = PlainLet
            | InstanceLet
            | SuperclassLet
            | NewtypeLet
              deriving (Show, Eq, Generic)

type Val  = Atom
type Type = Atom
type Kind = Type

type TC  = PrimTC  Atom
type Con = PrimCon Atom
type Op  = PrimOp  Atom
type Hof = PrimHof Atom

data Module = Module IRVariant [Decl] Bindings  deriving (Show, Eq)
type TopEnv = Scope

data IRVariant = Surface | Typed | Core | Simp | Evaluated
                 deriving (Show, Eq, Ord, Generic)

-- A subset of Type generated by the following grammar:
-- data ScalarTableType = TabType (Pi ScalarTableType) | Scalar BaseType
type ScalarTableType = Type
type ScalarTableVar  = VarP ScalarTableType

scalarTableBaseType :: ScalarTableType -> BaseType
scalarTableBaseType t = case t of
  TabTy _ a -> scalarTableBaseType a
  BaseTy b  -> b
  _         -> error $ "Not a scalar table: " ++ show t

-- === front-end language AST ===

type UExpr = WithSrc UExpr'
data UExpr' = UVar UVar
            | ULam UBinder UArrow UExpr
            | UPi  UPiBinder Arrow UType
            | UApp UArrow UExpr UExpr
            | UDecl UDecl UExpr
            | UFor Direction UBinder UExpr
            | UHole
            | UTabCon [UExpr] (Maybe UExpr)
            | UIndexRange (Limit UExpr) (Limit UExpr)
            | UPrimExpr (PrimExpr Name)
              deriving (Show, Eq, Generic)

data UDecl = ULet LetAnn UBinder UExpr  deriving (Show, Eq, Generic)

type UType  = UExpr
type UArrow = ArrowP ()
type UVar   = VarP ()

type UPat    = PatP  UVar
type UPat'   = PatP' UVar
type UBinder   = (UPat, Maybe UType)
type UPiBinder = VarP UType

data UModule = UModule [UDecl]  deriving (Show, Eq)
type SrcPos = (Int, Int)

type PatP  a = WithSrc (PatP' a)
data PatP' a = PatBind a
             | PatPair (PatP a) (PatP a)
             | PatUnit  deriving (Show, Eq, Functor, Foldable, Traversable)

data WithSrc a = WithSrc SrcPos a
                 deriving (Show, Eq, Functor, Foldable, Traversable)

srcPos :: WithSrc a -> SrcPos
srcPos (WithSrc pos _) = pos

-- === primitive constructors and operators ===

data PrimExpr e =
        TCExpr  (PrimTC  e)
      | ConExpr (PrimCon e)
      | OpExpr  (PrimOp  e)
      | HofExpr (PrimHof e)
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimTC e =
        BaseType  BaseType
      | ArrayType e         -- A pointer to memory storing a ScalarTableType value
      | IntRange e e
      | IndexRange e (Limit e) (Limit e)
      | IndexSlice e e      -- Sliced index set, slice length. Note that this is no longer an index set!
      | PairType e e
      | UnitType
      | SumType e e
      | RefType e e
      | TypeKind
      | EffectRowKind
        -- NOTE: This is just a hack so that we can construct an Atom from an Imp or Jax expression.
        --       In the future it might make sense to parametrize Atoms by the types
        --       of values they can hold.
        -- XXX: This one can temporarily also appear in the fully evaluated terms in TopLevel.
      | JArrayType [Int] ScalarBaseType
      | NewtypeApp e [e]  -- binding var args
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimCon e =
        Lit LitVal
      | ArrayLit e Array  -- Used to store results of module evaluation
      | AnyValue e        -- Produces an arbitrary value of a given type
      | SumCon e e e      -- (bool constructor tag (True is Left), left value, right value)
      | PairCon e e
      | UnitCon
      | RefCon e e
      | Coerce e e        -- Type, then value. See Type.hs for valid coerctions.
      | NewtypeCon e e    -- result type, argument
      | ClassDictHole e   -- Only used during type inference
      | Todo e
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimOp e =
        Fst e
      | Snd e
      | SumGet e Bool
      | SumTag e
      | TabCon e [e]                 -- table type elements
      | ScalarBinOp ScalarBinOp e e
      | ScalarUnOp ScalarUnOp e
      | Select e e e                 -- predicate, val-if-true, val-if-false
      | PrimEffect e (PrimEffect e)
      | IndexRef e e
      | FstRef e
      | SndRef e
      | FFICall String BaseType [e]
      | Inject e
      | ArrayOffset e e e            -- Second argument is the index for type checking,
                                     -- Third argument is the linear offset for evaluation
      | ArrayLoad e
      | SliceOffset e e              -- Index slice first, inner index second
      | SliceCurry  e e              -- Index slice first, curried index second
      -- SIMD operations
      | VectorBinOp ScalarBinOp e e
      | VectorPack [e]               -- List should have exactly vectorWidth elements
      | VectorIndex e e              -- Vector first, index second
      -- Idx (survives simplification, because we allow it to be backend-dependent)
      | IntAsIndex e e   -- index set, ordinal index
      | IndexAsInt e
      | IdxSetSize e
      | FromNewtypeCon e e  -- result type, argument
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimHof e =
        For Direction e
      | Tile Int e e          -- dimension number, tiled body, scalar body
      | While e e
      | SumCase e e e
      | RunReader e e
      | RunWriter e
      | RunState  e e
      | Linearize e
      | Transpose e
        deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data PrimEffect e = MAsk | MTell e | MGet | MPut e
    deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data ScalarBinOp = IAdd | ISub | IMul | IDiv | ICmp CmpOp
                 | FAdd | FSub | FMul | FDiv | FCmp CmpOp | Pow
                 | And | Or | Rem
                   deriving (Show, Eq, Generic)

data ScalarUnOp = Not | FNeg | IntToReal | BoolToInt | UnsafeIntToBool
                  deriving (Show, Eq, Generic)

data CmpOp = Less | Greater | Equal | LessEqual | GreaterEqual
             deriving (Show, Eq, Generic)

data Direction = Fwd | Rev  deriving (Show, Eq, Generic)

data Limit a = InclusiveLim a
             | ExclusiveLim a
             | Unlimited
               deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data ClassName = Data | VSpace | IdxSet | Eq | Ord deriving (Show, Eq, Generic)

data TyQual = TyQual Var ClassName  deriving (Show, Eq, Generic)

type PrimName = PrimExpr ()

strToName :: String -> Maybe PrimName
strToName s = M.lookup s builtinNames

nameToStr :: PrimName -> String
nameToStr prim = case lookup prim $ map swap $ M.toList builtinNames of
  Just s  -> s
  Nothing -> show prim

showPrimName :: PrimExpr e -> String
showPrimName prim = nameToStr $ fmap (const ()) prim

-- === effects ===

type Effect = (EffectName, Name)
data EffectRow = EffectRow [Effect] (Maybe Name)
                 deriving (Show, Generic)
data EffectName = Reader | Writer | State  deriving (Show, Eq, Ord, Generic)

data EffectSummary = NoEffects | SomeEffects  deriving (Show, Eq, Ord, Generic)

pattern Pure :: EffectRow
pattern Pure = EffectRow [] Nothing

instance Eq EffectRow where
  EffectRow effs t == EffectRow effs' t' =
    sort effs == sort effs' && t == t'

instance Semigroup EffectSummary where
  NoEffects <> NoEffects = NoEffects
  _ <> _ = SomeEffects

instance Monoid EffectSummary where
  mempty = NoEffects

-- === top-level constructs ===

data SourceBlock = SourceBlock
  { sbLine     :: Int
  , sbOffset   :: Int
  , sbLogLevel :: LogLevel
  , sbText     :: String
  , sbContents :: SourceBlock'
  , sbId       :: Maybe BlockId }  deriving (Show)

type BlockId = Int
type ReachedEOF = Bool
data SourceBlock' = RunModule UModule
                  | Command CmdName (Name, UModule)
                  | GetNameType Name
                  | IncludeSourceFile String
                  | LoadData UBinder DataFormat String
                  | ProseBlock String
                  | CommentLine
                  | EmptyLines
                  | UnParseable ReachedEOF String
                    deriving (Show, Eq, Generic)

data CmdName = GetType | EvalExpr OutFormat | Dump DataFormat String
                deriving  (Show, Eq, Generic)

data LogLevel = LogNothing | PrintEvalTime | LogPasses [PassName] | LogAll
                deriving  (Show, Eq, Generic)

-- === imperative IR ===

data ImpFunction = ImpFunction [ScalarTableVar] [ScalarTableVar] ImpProg  -- destinations first
                   deriving (Show, Eq)
newtype ImpProg = ImpProg [ImpStatement]
                  deriving (Show, Eq, Generic, Semigroup, Monoid)
type ImpStatement = (Maybe IVar, ImpInstr)

data ImpInstr = Load  IExpr
              | Store IExpr IExpr           -- Destination first
              | Alloc ScalarTableType Size  -- Second argument is the size of the table
              | Free IVar
                                            -- Second argument is the linear offset for code generation
                                            -- Third argument is the result type for type checking
              | IOffset IExpr IExpr ScalarTableType
              | Loop Direction IVar Size ImpProg
              | IWhile IExpr ImpProg
              | IPrimOp IPrimOp
                deriving (Show, Eq)

data IExpr = ILit LitVal
           | IVar IVar
             deriving (Show, Eq)

type IPrimOp = PrimOp IExpr
type IVal = IExpr  -- only ILit and IRef constructors
type IVar = VarP IType
data IType = IValType BaseType
           | IRefType ScalarTableType -- This represents ArrayType (ScalarTableType)
             deriving (Show, Eq)

type Size  = IExpr

-- === some handy monoids ===

data SetVal a = Set a | NotSet
newtype MonMap k v = MonMap (M.Map k v)  deriving (Show, Eq)

instance Semigroup (SetVal a) where
  x <> NotSet = x
  _ <> Set x  = Set x

instance Monoid (SetVal a) where
  mempty = NotSet

instance (Ord k, Semigroup v) => Semigroup (MonMap k v) where
  MonMap m <> MonMap m' = MonMap $ M.unionWith (<>) m m'

instance (Ord k, Semigroup v) => Monoid (MonMap k v) where
  mempty = MonMap mempty

monMapSingle :: k -> v -> MonMap k v
monMapSingle k v = MonMap (M.singleton k v)

monMapLookup :: (Monoid v, Ord k) => MonMap k v -> k -> v
monMapLookup (MonMap m) k = case M.lookup k m of Nothing -> mempty
                                                 Just v  -> v

-- === passes ===

data PassName = Parse | TypePass | SynthPass | SimpPass | ImpPass | JitPass
              | Flops | LLVMOpt | AsmPass | JAXPass | JAXSimpPass | LLVMEval
              | ResultPass | JaxprAndHLO
                deriving (Ord, Eq, Bounded, Enum)

instance Show PassName where
  show p = case p of
    Parse    -> "parse" ; TypePass -> "typed"   ; SynthPass -> "synth"
    SimpPass -> "simp"  ; ImpPass  -> "imp"     ; JitPass   -> "llvm"
    Flops    -> "flops" ; LLVMOpt  -> "llvmopt" ; AsmPass   -> "asm"
    JAXPass  -> "jax"   ; JAXSimpPass -> "jsimp"; ResultPass -> "result"
    LLVMEval -> "llvmeval" ; JaxprAndHLO -> "jaxprhlo";

-- === outputs ===

type LitProg = [(SourceBlock, Result)]
type SrcCtx = Maybe SrcPos
data Result = Result [Output] (Except ())  deriving (Show, Eq)

data Output = TextOut String
            | HeatmapOut Int Int (V.Vector Double)
            | ScatterOut (V.Vector Double) (V.Vector Double)
            | PassInfo PassName String
            | EvalTime Double
            | MiscLog String
              deriving (Show, Eq, Generic)

data OutFormat = Printed | Heatmap | Scatter   deriving (Show, Eq, Generic)
data DataFormat = DexObject | DexBinaryObject  deriving (Show, Eq, Generic)

data Err = Err ErrType SrcCtx String  deriving (Show, Eq)
instance Exception Err

data ErrType = NoErr
             | ParseErr
             | TypeErr
             | KindErr
             | LinErr
             | UnboundVarErr
             | RepeatedVarErr
             | CompilerErr
             | IRVariantErr
             | NotImplementedErr
             | DataIOErr
             | MiscErr
               deriving (Show, Eq)

type Except = Either Err

throw :: MonadError Err m => ErrType -> String -> m a
throw e s = throwError $ Err e Nothing s

throwIf :: MonadError Err m => Bool -> ErrType -> String -> m ()
throwIf True  e s = throw e s
throwIf False _ _ = return ()

modifyErr :: MonadError e m => m a -> (e -> e) -> m a
modifyErr m f = catchError m $ \e -> throwError (f e)

addContext :: MonadError Err m => String -> m a -> m a
addContext s m = modifyErr m $ \(Err e p s') -> Err e p (s' ++ "\n" ++ s)

addSrcContext :: MonadError Err m => SrcCtx -> m a -> m a
addSrcContext ctx m = modifyErr m updateErr
  where
    updateErr :: Err -> Err
    updateErr (Err e ctx' s) = case ctx' of Nothing -> Err e ctx  s
                                            Just _  -> Err e ctx' s

catchIOExcept :: (MonadIO m , MonadError Err m) => IO a -> m a
catchIOExcept m = (liftIO >=> liftEither) $ (liftM Right m) `catches`
  [ Handler $ \(e::Err)           -> return $ Left e
  , Handler $ \(e::IOError)       -> return $ Left $ Err DataIOErr   Nothing $ show e
  , Handler $ \(e::SomeException) -> return $ Left $ Err CompilerErr Nothing $ show e
  ]

liftEitherIO :: (Exception e, MonadIO m) => Either e a -> m a
liftEitherIO (Left err) = liftIO $ throwIO err
liftEitherIO (Right x ) = return x

instance MonadFail (Either Err) where
  fail s = Left $ Err CompilerErr Nothing s

-- === UExpr free variables ===

type UVars = Env ()

uVarsAsGlobal :: UVars -> UVars
uVarsAsGlobal vs = foldMap (\v -> (asGlobal v :>()) @> ()) $ envNames vs

class HasUVars a where
  freeUVars :: a -> UVars

instance HasUVars a => HasUVars (WithSrc a) where
  freeUVars (WithSrc _ e) = freeUVars e

instance HasUVars UExpr' where
  freeUVars expr = case expr of
    UVar v -> v@>()
    ULam b _ body -> uAbsFreeVars b body
    UPi b arr ty ->
      freeUVars (varAnn b) <>
      ((freeUVars arr <> freeUVars ty) `envDiff` (b@>()))
    -- TODO: maybe distinguish table arrow application
    -- (otherwise `x.i` and `x i` are the same)
    UApp _ f x -> freeUVars f <> freeUVars x
    UDecl (ULet _ b rhs) body -> freeUVars rhs <> uAbsFreeVars b body
    UFor _ b body -> uAbsFreeVars b body
    UHole -> mempty
    UTabCon xs n -> foldMap freeUVars xs <> foldMap freeUVars n
    UIndexRange low high -> foldMap freeUVars low <> foldMap freeUVars high
    UPrimExpr _ -> mempty

instance HasUVars UDecl where
  freeUVars (ULet _ p expr) = uBinderFreeVars p <> freeUVars expr

instance HasUVars UModule where
  freeUVars (UModule []) = mempty
  freeUVars (UModule (ULet _ b rhs : rest)) =
    freeUVars rhs <> uAbsFreeVars b (UModule rest)

instance HasUVars SourceBlock where
  freeUVars block = uVarsAsGlobal $
    case sbContents block of
      RunModule (   m) -> freeUVars m
      Command _ (_, m) -> freeUVars m
      GetNameType v -> (v:>()) @> ()
      _ -> mempty

instance HasUVars EffectRow where
  freeUVars (EffectRow effs tailVar) =
    foldMap (nameAsEnv . snd) effs <> foldMap nameAsEnv tailVar

instance HasUVars eff => HasUVars (ArrowP eff) where
  freeUVars (PlainArrow eff) = freeUVars eff
  freeUVars _ = mempty

uAbsFreeVars :: HasUVars a => UBinder -> a -> UVars
uAbsFreeVars (pat, ann) body =
  foldMap freeUVars ann <> (freeUVars body `envDiff` uPatBoundVars pat)

uBinderFreeVars :: UBinder -> UVars
uBinderFreeVars (_, ann) = foldMap freeUVars ann

sourceBlockBoundVars :: SourceBlock -> UVars
sourceBlockBoundVars block = uVarsAsGlobal $
  case sbContents block of
    RunModule m -> uModuleBoundVars m
    LoadData (WithSrc _ p, _) _ _ -> foldMap (@>()) p
    _                             -> mempty

uPatBoundVars :: UPat -> UVars
uPatBoundVars (WithSrc _ pat) = foldMap (@>()) pat

uModuleBoundVars :: UModule -> UVars
uModuleBoundVars (UModule decls) =
  foldMap (\(ULet _ (p,_) _) -> uPatBoundVars p) decls

nameAsEnv :: Name -> UVars
nameAsEnv v = (v:>())@>()

-- === Expr free variables and substitutions ===

data BinderInfo =
        LamBound (ArrowP ())
        -- TODO: make the expression optional, for when it's effectful?
        -- (or we could put the effect tag on the let annotation)
      | LetBound LetAnn Expr
      | PiBound
      | UnknownBinder
        deriving (Show, Eq, Generic)

type SubstEnv = Env Atom
type Bindings = Env (Type, BinderInfo)
type Scope = Bindings  -- when we only care about the names, not the payloads
type ScopedSubstEnv = (SubstEnv, Bindings)

scopelessSubst :: HasVars a => SubstEnv -> a -> a
scopelessSubst env x = subst (env, scope) x
  where scope = foldMap freeVars env <> (freeVars x `envDiff` env)

declAsScope :: Decl -> Scope
declAsScope (Let ann v expr) = v @> (varType v, LetBound ann expr)

bindingsAsVars :: Bindings -> [Var]
bindingsAsVars env = [v:>ty | (v, (ty, _)) <- envPairs env]

class HasVars a where
  freeVars :: a -> Scope
  subst :: ScopedSubstEnv -> a -> a

instance (Show a, HasVars a, Eq a) => Eq (Abs a) where
  Abs (NoName:>a) b == Abs (NoName:>a') b' = a == a' && b == b'
  ab@(Abs (_:>a) _) == ab'@(Abs (_:>a') _) =
    a == a' && applyAbs ab v == applyAbs ab' v
    where v = Var $ freshSkolemVar (ab, ab') a

freshSkolemVar :: HasVars a => a -> Type -> Var
freshSkolemVar x ty = rename (rawName Skolem "skol" :> ty) (freeVars x)

-- NOTE: We don't have an instance for VarP, because it's used to represent
--       both binders and regular variables, but each requires different treatment
freeBinderTypeVars :: Var -> Scope
freeBinderTypeVars (_ :> t) = freeVars t

applyAbs :: HasVars a => Abs a -> Atom -> a
applyAbs (Abs v body) x = scopelessSubst (v@>x) body

makeAbs :: HasVars a => Var -> a -> Abs a
makeAbs v body | v `isin` freeVars body = Abs v body
               | otherwise              = Abs (NoName:> varAnn v) body

absArgType :: Abs a -> Type
absArgType (Abs (_:>ty) _) = ty

varFreeVars :: Var -> Scope
varFreeVars v@(_:>t) = (v@>(t, UnknownBinder)) <> freeVars t

-- TODO: de-dup with `zipEnv`
newEnv :: [VarP ann] -> [a] -> Env a
newEnv vs xs = fold $ zipWith (@>) vs xs

instance HasVars Arrow where
  freeVars arrow = case arrow of
    PlainArrow eff -> freeVars eff
    _ -> mempty

  subst env arrow = case arrow of
    PlainArrow eff -> PlainArrow $ subst env eff
    _ -> arrow

arrowEff :: Arrow -> EffectRow
arrowEff (PlainArrow eff) = eff
arrowEff _ = Pure

substVar :: (SubstEnv, Scope) -> Var -> Atom
substVar env@(sub, scope) v = case envLookup sub v of
  Nothing -> Var $ fmap (subst env) v
  Just x' -> deShadow x' scope

deShadow :: HasVars a => a -> Scope -> a
deShadow x scope = subst (mempty, scope) x

instance HasVars Expr where
  freeVars expr = case expr of
    App f x -> freeVars f <> freeVars x
    Atom x  -> freeVars x
    Op  e   -> foldMap freeVars e
    Hof e   -> foldMap freeVars e

  subst env expr = case expr of
    App f x -> App (subst env f) (subst env x)
    Atom x  -> Atom $ subst env x
    Op  e   -> Op  $ fmap (subst env) e
    Hof e   -> Hof $ fmap (subst env) e

instance HasVars Decl where
  freeVars (Let _ bs expr) = foldMap freeVars bs <> freeVars expr
  subst env (Let ann (v:>ty) bound) =
    Let ann (v:> subst env ty) (subst env bound)

instance HasVars Block where
  freeVars (Block [] result) = freeVars result
  freeVars (Block (decl@(Let _ b _):decls) result) =
    freeVars decl <> (freeVars body `envDiff` (b@>()))
    where body = Block decls result

  subst env (Block decls result) = do
    let (decls', env') = catMap substDecl env decls
    let result' = subst (env <> env') result
    Block decls' result'

instance HasVars Atom where
  freeVars atom = case atom of
    Var v   -> varFreeVars v
    Lam lam -> freeVars lam
    Pi  ty  -> freeVars ty
    Con con -> foldMap freeVars con
    TC  tc  -> foldMap freeVars tc
    Eff eff -> freeVars eff

  subst env atom = case atom of
    Var v   -> substVar env v
    Lam lam -> Lam $ subst env lam
    Pi  ty  -> Pi  $ subst env ty
    TC  tc  -> TC  $ fmap (subst env) tc
    Con con -> Con $ fmap (subst env) con
    Eff eff -> Eff $ subst env eff

instance HasVars Module where
  freeVars (Module variant decls bindings) = case decls of
    [] -> freeVars bindings `envDiff` bindings
    Let _ b rhs : rest -> freeVars rhs
                       <> freeVars (Abs b (Module variant rest bindings))

  subst env (Module variant decls bindings) = Module variant decls' bindings'
    where
      (decls', env') = catMap substDecl env decls
      bindings' = subst (env <> env') bindings

instance HasVars EffectRow where
  freeVars (EffectRow row t) =
       foldMap (\(_,v) -> (v:>())@>(TyKind , UnknownBinder)) row
    <> foldMap (\v     -> (v:>())@>(EffKind, UnknownBinder)) t

  subst (env, _) (EffectRow row t) = extendEffRow
    (fmap (\(effName, v) -> (effName, substName env v)) row)
    (substEffTail env t)

instance HasVars BinderInfo where
  freeVars binfo = case binfo of
   LetBound _ expr -> freeVars expr
   _ -> mempty

  subst env binfo = case binfo of
   LetBound a expr -> LetBound a $ subst env expr
   _ -> binfo

instance HasVars LetAnn where
  freeVars _ = mempty
  subst _ ann = ann

substEffTail :: SubstEnv -> Maybe Name -> EffectRow
substEffTail _ Nothing = EffectRow [] Nothing
substEffTail env (Just v) = case envLookup env (v:>()) of
  Nothing -> EffectRow [] (Just v)
  Just (Var (v':>_)) -> EffectRow [] (Just v')
  Just (Eff r) -> r
  _ -> error "Not a valid effect substitution"

substName :: SubstEnv -> Name -> Name
substName env v = case envLookup env (v:>()) of
  Nothing -> v
  Just (Var (v':>_)) -> v'
  _ -> error "Should only substitute with a name"

extendEffRow :: [Effect] -> EffectRow -> EffectRow
extendEffRow effs (EffectRow effs' t) = EffectRow (effs <> effs') t

instance HasVars a => HasVars (Abs a) where
  freeVars (Abs b body) =
    freeBinderTypeVars b <> (freeVars body `envDiff` (b@>()))

  subst env (Abs (v:>ty) body) = Abs b body'
    where (b, env') = refreshBinder env (v:> subst env ty)
          body' = subst (env <> env') body

substDecl :: ScopedSubstEnv -> Decl -> (Decl, ScopedSubstEnv)
substDecl env (Let ann (v:>ty) bound) = (Let ann b (subst env bound), env')
  where (b, env') = refreshBinder env (v:> subst env ty)

refreshBinder :: ScopedSubstEnv -> Var -> (Var, ScopedSubstEnv)
refreshBinder (_, scope) b = (b', env')
  where b' = rename b scope
        env' = (b@>Var b', b'@>(varType b, UnknownBinder))

instance HasVars () where
  freeVars () = mempty
  subst _ () = ()

instance (HasVars a, HasVars b) => HasVars (a, b) where
  freeVars (x, y) = freeVars x <> freeVars y
  subst env (x, y) = (subst env x, subst env y)

instance (HasVars a, HasVars b) => HasVars (Either a b)where
  freeVars (Left  x) = freeVars x
  freeVars (Right x) = freeVars x
  subst = error "not implemented"

instance HasVars a => HasVars (Maybe a) where
  freeVars x = foldMap freeVars x
  subst env x = fmap (subst env) x

instance HasVars a => HasVars (Env a) where
  freeVars x = foldMap freeVars x
  subst env x = fmap (subst env) x

instance HasVars a => HasVars [a] where
  freeVars x = foldMap freeVars x
  subst env x = fmap (subst env) x

instance Eq SourceBlock where
  x == y = sbText x == sbText y

instance Ord SourceBlock where
  compare x y = compare (sbText x) (sbText y)

-- === Synonyms ===

varType :: Var -> Type
varType = varAnn

infixr 1 -->
infixr 1 --@
infixr 2 ==>

(-->) :: Type -> Type -> Type
a --> b = Pi (Abs (NoName:>a) (PureArrow, b))

(--@) :: Type -> Type -> Type
a --@ b = Pi (Abs (NoName:>a) (LinArrow, b))

(==>) :: Type -> Type -> Type
a ==> b = Pi (Abs (NoName:>a) (TabArrow, b))

pattern IntLitExpr :: Int -> UExpr'
pattern IntLitExpr x = UPrimExpr (ConExpr (Lit (IntLit x)))

pattern RealLitExpr :: Double -> UExpr'
pattern RealLitExpr x = UPrimExpr (ConExpr (Lit (RealLit x)))

pattern IntVal :: Int -> Atom
pattern IntVal x = Con (Lit (IntLit x))

pattern RealVal :: Double -> Atom
pattern RealVal x = Con (Lit (RealLit x))

pattern BoolVal :: Bool -> Atom
pattern BoolVal x = Con (Lit (BoolLit x))

pattern ArrayVal :: Type -> Array -> Atom
pattern ArrayVal t arr = Con (ArrayLit t arr)

pattern SumVal :: Atom -> Atom -> Atom -> Atom
pattern SumVal t l r = Con (SumCon t l r)

pattern PairVal :: Atom -> Atom -> Atom
pattern PairVal x y = Con (PairCon x y)

pattern PairTy :: Type -> Type -> Type
pattern PairTy x y = TC (PairType x y)

pattern UnitVal :: Atom
pattern UnitVal = Con UnitCon

pattern UnitTy :: Type
pattern UnitTy = TC UnitType

pattern JArrayTy :: [Int] -> ScalarBaseType -> Type
pattern JArrayTy shape b = TC (JArrayType shape b)

pattern BaseTy :: BaseType -> Type
pattern BaseTy b = TC (BaseType b)

pattern SumTy :: Type -> Type -> Type
pattern SumTy l r = TC (SumType l r)

pattern RefTy :: Atom -> Type -> Type
pattern RefTy r a = TC (RefType r a)

pattern IntTy :: Type
pattern IntTy = TC (BaseType (Scalar IntType))

pattern BoolTy :: Type
pattern BoolTy = TC (BaseType (Scalar BoolType))

pattern RealTy :: Type
pattern RealTy = TC (BaseType (Scalar RealType))

pattern TyKind :: Kind
pattern TyKind = TC TypeKind

pattern EffKind :: Kind
pattern EffKind = TC EffectRowKind

pattern FixedIntRange :: Int -> Int -> Type
pattern FixedIntRange low high = TC (IntRange (IntVal low) (IntVal high))

pattern PureArrow :: Arrow
pattern PureArrow = PlainArrow Pure

pattern ArrayTy :: Type -> Type
pattern ArrayTy t = TC (ArrayType t)

pattern TabTy :: Var -> Type -> Type
pattern TabTy v i = Pi (Abs v (TabArrow, i))

pattern TabTyAbs :: PiType -> Type
pattern TabTyAbs a <- Pi a@(Abs _ (TabArrow, _))

pattern LamVal :: Var -> Block -> Atom
pattern LamVal v b <- Lam (Abs v (_, b))

pattern TabVal :: Var -> Block -> Atom
pattern TabVal v b = Lam (Abs v (TabArrow, b))

pattern TabValA :: Var -> Atom -> Atom
pattern TabValA v a = Lam (Abs v (TabArrow, (Block [] (Atom a))))

isTabTy :: Type -> Bool
isTabTy (TabTy _ _) = True
isTabTy _ = False

mkConsListTy :: [Type] -> Type
mkConsListTy tys = foldr PairTy UnitTy tys

mkConsList :: [Atom] -> Atom
mkConsList xs = foldr PairVal UnitVal xs

fromConsListTy :: MonadError Err m => Type -> m [Type]
fromConsListTy ty = case ty of
  UnitTy         -> return []
  PairTy t rest -> (t:) <$> fromConsListTy rest
  _              -> throw CompilerErr $ "Not a pair or unit: " ++ show ty

fromConsList :: MonadError Err m => Atom -> m [Atom]
fromConsList xs = case xs of
  UnitVal        -> return []
  PairVal x rest -> (x:) <$> fromConsList rest
  _              -> throw CompilerErr $ "Not a pair or unit: " ++ show xs

pattern FunTy :: Binder -> EffectRow -> Type -> Type
pattern FunTy b eff bodyTy = Pi (Abs b (PlainArrow eff, bodyTy))

pattern BinaryFunTy :: Binder -> Binder -> EffectRow -> Type -> Type
pattern BinaryFunTy b1 b2 eff bodyTy = FunTy b1 Pure (FunTy b2 eff bodyTy)

pattern BinaryFunVal :: Binder -> Binder -> EffectRow -> Block -> Type
pattern BinaryFunVal b1 b2 eff body =
          Lam (Abs b1 (PureArrow, Block [] (Atom (
          Lam (Abs b2 (PlainArrow eff, body))))))

-- TODO: Enable once https://gitlab.haskell.org//ghc/ghc/issues/13363 is fixed...
-- {-# COMPLETE TypeVar, ArrowType, TabTy, Forall, TypeAlias, Effect, NoAnn, TC #-}

-- TODO: Can we derive these generically? Or use Show/Read?
--       (These prelude-only names don't have to be pretty.)
builtinNames :: M.Map String PrimName
builtinNames = M.fromList
  [ ("iadd", binOp IAdd), ("isub", binOp ISub)
  , ("imul", binOp IMul), ("fdiv", binOp FDiv)
  , ("fadd", binOp FAdd), ("fsub", binOp FSub)
  , ("fmul", binOp FMul), ("idiv", binOp IDiv)
  , ("pow" , binOp Pow ), ("rem" , binOp Rem )
  , ("ieq" , binOp (ICmp Equal  )), ("feq", binOp (FCmp Equal  ))
  , ("igt" , binOp (ICmp Greater)), ("fgt", binOp (FCmp Greater))
  , ("ilt" , binOp (ICmp Less)),    ("flt", binOp (FCmp Less))
  , ("and" , binOp And ), ("or"  , binOp Or  ), ("not" , unOp  Not )
  , ("fneg", unOp  FNeg)
  , ("vfadd", vbinOp FAdd), ("vfsub", vbinOp FSub), ("vfmul", vbinOp FMul)
  , ("True" , ConExpr $ Lit $ BoolLit True)
  , ("False", ConExpr $ Lit $ BoolLit False)
  , ("inttoreal", unOp IntToReal)
  , ("booltoint", unOp BoolToInt)
  , ("asint"       , OpExpr $ IndexAsInt ())
  , ("idxSetSize"  , OpExpr $ IdxSetSize ())
  , ("asidx"       , OpExpr $ IntAsIndex () ())
  , ("select"      , OpExpr $ Select () () ())
  , ("todo"       , ConExpr $ Todo ())
  , ("ask"        , OpExpr $ PrimEffect () $ MAsk)
  , ("tell"       , OpExpr $ PrimEffect () $ MTell ())
  , ("get"        , OpExpr $ PrimEffect () $ MGet)
  , ("put"        , OpExpr $ PrimEffect () $ MPut  ())
  , ("indexRef"   , OpExpr $ IndexRef () ())
  , ("inject"     , OpExpr $ Inject ())
  , ("newtypeCon"      , ConExpr $ NewtypeCon     () ())
  , ("fromNewtypeCon"  , OpExpr  $ FromNewtypeCon () ())
  , ("while"           , HofExpr $ While () ())
  , ("linearize"       , HofExpr $ Linearize ())
  , ("linearTranspose" , HofExpr $ Transpose ())
  , ("runReader"       , HofExpr $ RunReader () ())
  , ("runWriter"       , HofExpr $ RunWriter    ())
  , ("runState"        , HofExpr $ RunState  () ())
  , ("caseAnalysis"    , HofExpr $ SumCase () () ())
  , ("tiled"           , HofExpr $ Tile 0 () ())
  , ("tiledd"          , HofExpr $ Tile 1 () ())
  , ("Int"     , TCExpr $ BaseType $ Scalar IntType)
  , ("Real"    , TCExpr $ BaseType $ Scalar RealType)
  , ("Bool"    , TCExpr $ BaseType $ Scalar BoolType)
  , ("TyKind"  , TCExpr $ TypeKind)
  , ("IntRange", TCExpr $ IntRange () ())
  , ("Ref"     , TCExpr $ RefType () ())
  , ("PairType", TCExpr $ PairType () ())
  , ("SumType" , TCExpr $ SumType () ())
  , ("UnitType", TCExpr $ UnitType)
  , ("EffKind" , TCExpr $ EffectRowKind)
  , ("IndexSlice", TCExpr $ IndexSlice () ())
  , ("pair", ConExpr $ PairCon () ())
  , ("fst", OpExpr $ Fst ())
  , ("snd", OpExpr $ Snd ())
  , ("fstRef", OpExpr $ FstRef ())
  , ("sndRef", OpExpr $ SndRef ())
  , ("sumCon", ConExpr $ SumCon () () ())
  , ("anyVal", ConExpr $ AnyValue ())
  , ("VectorRealType",  TCExpr $ BaseType $ Vector RealType)
  , ("vectorPack", OpExpr $ VectorPack $ replicate vectorWidth ())
  , ("vectorIndex", OpExpr $ VectorIndex () ())
  , ("unsafeAsIndex", ConExpr $ Coerce () ())
  , ("sliceOffset", OpExpr $ SliceOffset () ())
  , ("sliceCurry", OpExpr $ SliceCurry () ())
  ]
  where
    vbinOp op = OpExpr $ VectorBinOp op () ()
    binOp  op = OpExpr $ ScalarBinOp op () ()
    unOp   op = OpExpr $ ScalarUnOp  op ()

instance Store a => Store (PrimOp  a)
instance Store a => Store (PrimCon a)
instance Store a => Store (PrimTC  a)
instance Store a => Store (PrimHof a)
instance Store a => Store (Abs a)
instance Store a => Store (ArrowP a)
instance Store a => Store (Limit a)
instance Store a => Store (PrimEffect a)
instance Store Atom
instance Store Expr
instance Store Block
instance Store Decl
instance Store EffectName
instance Store EffectRow
instance Store Direction
instance Store ScalarUnOp
instance Store ScalarBinOp
instance Store CmpOp
instance Store LetAnn
instance Store BinderInfo
