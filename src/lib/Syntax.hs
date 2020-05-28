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
    Type, Kind, BaseType (..), Effect, EffectiveType, Mult,
    ClassName (..), TyQual (..), SrcPos, Pat, Var, Dep, Expr (..), Decl (..),
    CExpr, Con, Atom (..), LamExpr (..),
    PrimExpr (..), PrimCon (..), LitVal (..), PrimEffect (..), PrimOp (..),
    VSpaceOp (..), ScalarBinOp (..), ScalarUnOp (..), CmpOp (..), SourceBlock (..),
    ReachedEOF, SourceBlock' (..), TypeEnv, SubstEnv, Scope, RuleEnv,
    CmdName (..), Val, TopInfEnv, TopSimpEnv, TopEnv (..),
    ModuleP (..), ModuleType, Module, ImpFunction (..),
    ImpProg (..), ImpStatement, ImpInstr (..), IExpr (..), IVal, IPrimOp,
    IVar, IType (..), ArrayType, IArrayType, SetVal (..), MonMap (..), LitProg,
    SrcCtx, Result (..), Output (..), OutFormat (..), DataFormat (..),
    Err (..), ErrType (..), Except, throw, throwIf, modifyErr, addContext,
    addSrcContext, catchIOExcept, liftEitherIO, (-->), (--@), (==>),
    sourceBlockBoundVars, PassName (..), parsePassName,
    TraversableExpr, traverseExpr, fmapExpr, freeVars, HasVars, declBoundVars,
    strToName, nameToStr, unzipExpr, bind, uDeclBoundVars,
    noEffect, isPure, EffectName (..), EffectRow, Vars,
    traverseTyCon, fmapTyCon, monMapSingle, monMapLookup, PiType (..),
    newEnv, Direction (..), ArrayRef, Array,
    Limit (..), TyCon (..), addBlockId, ArrowHead (..),
    JointTypeEnv(..), fromNamedEnv, jointEnvLookup, extendNamed, extendDeBruijn,
    jointEnvGet, Implicity (..), UExpr (..), UExpr' (..), UType, UBinder, UVar,
    Pat, UModule (..), UDecl (..), ULamExpr (..), UPiType (..),
    pattern IntVal, pattern UnitTy, pattern PairTy, pattern TupTy,
    pattern TabTy, pattern NonLin, pattern Lin, pattern FixedIntRange,
    pattern RefTy, pattern BoolTy, pattern IntTy, pattern RealTy,
    pattern RecTy, pattern SumTy, pattern ArrayTy, pattern BaseTy, pattern UnitVal,
    pattern PairVal, pattern TupVal, pattern RecVal, pattern SumVal,
    pattern RealVal, pattern BoolVal, pattern TyKind)
  where

import qualified Data.Map.Strict as M
import Control.Applicative
import Control.Exception hiding (throw)
import Control.Monad.Fail
import Control.Monad.Identity
import Control.Monad.Writer
import Control.Monad.Except hiding (Except)
import Control.Monad.Reader
import qualified Data.Vector.Unboxed as V
import Data.Foldable (fold)
import Data.Tuple (swap)
import Data.Maybe (fromJust)
import Control.Applicative (liftA3)
import GHC.Generics

import Record
import Env
import Array

-- === types ===

data Atom = Var Var
          | Con (PrimCon Type Atom LamExpr)
          | TC (TyCon Type Atom)
          | ArrowType Implicity Mult (PiType EffectiveType)
          | TabType (PiType Type)        -- TODO: merge with ArrowType
          | Effect (EffectRow Type) (Maybe Type) -- (Maybe Type) for the optional row tail variable
          | NoAnn
            deriving (Show, Eq, Generic)

type Type = Atom
type Kind = Type

data TyCon ty e = BaseType BaseType
                | IntRange e e
                | IndexRange ty (Limit e) (Limit e)
                | ArrayType ArrayType
                | RecType (Record ty)
                | SumType (ty, ty)
                | RefType ty
                | TabTypeCon ty
                | TypeApp ty [ty]
                | LinCon
                | NonLinCon
                | TypeKind
                | ArrowKind [ty] ty  -- TODO: remove
                | MultKind
                | EffectKind
                  deriving (Show, Eq, Generic)

type Var  = VarP Type

-- This represents a row like {Writer (x :: Ref t), Reader (y :: Ref t')}
-- as the following map: {x: (Writer, t), y: (Reader, t')}.
type EffectRow a = Env (EffectName, a)

data EffectName = Reader | Writer | State  deriving (Eq, Show, Generic)

-- TODO: Make a functor over EffectiveType (TabType doesn't have effects)
data PiType b = Pi Type b  deriving (Eq, Show)

data TyQual = TyQual Var ClassName  deriving (Eq, Show)

type Mult   = Type
type Dep    = Type
type Effect = Type
type EffectiveType = (Effect, Type)

data ClassName = Data | VSpace | IdxSet | Eq | Ord deriving (Show, Eq, Generic)

data Limit a = InclusiveLim a
             | ExclusiveLim a
             | Unlimited
               deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

type TypeEnv  = Env Type
type SubstEnv = Env Atom

type TopInfEnv  = (TypeEnv, Env Type)
type TopSimpEnv = SubstEnv
type RuleEnv = Env Atom
data TopEnv = TopEnv TopInfEnv TopSimpEnv RuleEnv
              deriving (Show, Eq, Generic)

data Implicity = ImplicitArg Name | Expl  deriving (Show, Eq, Generic)

type SrcPos = (Int, Int)

-- TODO: allow `Atom` under `CExpr`
type Scope = Env (Maybe (Either Atom CExpr))

noEffect :: Effect
noEffect = Effect mempty Nothing

isPure :: Effect -> Bool
isPure (Effect eff Nothing) | eff == mempty = True
isPure _ = False

type ModuleType = ([Var], [Var])
data ModuleP body = Module (Maybe BlockId) ModuleType body  deriving (Show, Eq)

-- === front-end language AST ===

data UExpr = UPos SrcPos UExpr'  deriving (Show, Eq, Generic)

data UExpr' = UVar UVar
            | ULam   ArrowHead ULamExpr
            | UApp   ArrowHead UExpr UExpr
            | UArrow ArrowHead UPiType
            | UFor Direction ULamExpr
            | UDecl UDecl UExpr
            | UPrimExpr (PrimExpr Name Name Name)
            | UAnnot UExpr UType
              deriving (Show, Eq, Generic)

data ArrowHead = PlainArrow
               | ImplicitArrow
               | TabArrow
               | LinArrow
                 deriving (Show, Eq, Generic)

data UDecl = ULet Pat UExpr         deriving (Show, Eq, Generic)
data ULamExpr = ULamExpr Pat UExpr  deriving (Show, Eq, Generic)
data UPiType  = UPi UPiBinder UType  deriving (Show, Eq, Generic)

type UType = UExpr
type UVar    = VarP ()
type UBinder = VarP (Maybe UType)
type UPiBinder = VarP UType
type Pat = RecTree UBinder

data UModule = UModule [Name] [Name] [UDecl]  deriving (Show, Eq)

-- === normalized core IR ===

data Expr = Decl Decl Expr
          | CExpr CExpr
          | Atom Atom
            deriving (Show, Eq, Generic)

data Decl = Let Var CExpr  deriving (Show, Eq, Generic)

type CExpr = PrimOp  Type Atom LamExpr
type Con   = PrimCon Type Atom LamExpr

type Module = ModuleP Expr
type Val = Atom

-- === primitive constructors and operators ===

data LamExpr = LamExpr Var Expr  deriving (Show, Eq, Generic)

data PrimExpr ty e lam = OpExpr  (PrimOp ty e lam)
                       | ConExpr (PrimCon ty e lam)
                       | TyExpr  (TyCon ty e)
                         deriving (Show, Eq, Generic)

data PrimCon ty e lam =
        Lit LitVal
      | ArrayLit Array
      | Lam Implicity ty ty lam  -- First type for linearity, second for effects
      | AnyValue ty        -- Produces an arbitrary value of a given type
      | SumCon e e e       -- (bool constructor tag (True is Left), left value, right value)
      | RecCon (Record e)
      | AsIdx ty e         -- Construct an index from its ordinal index (zero-based int)
      | AFor ty e
      | AGet e
      | Todo ty
        deriving (Show, Eq, Generic)

data PrimOp ty e lam =
        App ty e e  -- Type argument used only for linearity
      | TApp e [ty]
      | For Direction lam
      | TabGet e e
      | SumCase e lam lam
      | RecGet e RecField
      | SumGet e Bool
      | SumTag e
      | ArrayGep e e
      | LoadScalar e
      | TabCon ty ty [e]
      | ScalarBinOp ScalarBinOp e e
      | ScalarUnOp ScalarUnOp e
      | VSpaceOp ty (VSpaceOp e)
      | Select ty e e e
      | PrimEffect e (PrimEffect e)
      | RunReader e  lam
      | RunWriter    lam
      | RunState  e  lam
      | IndexEff EffectName e e lam
      | Linearize lam | Transpose lam
      | FFICall String [ty] ty [e]
      | NewtypeCast ty e
      | Inject e
      -- Typeclass operations
      -- Eq and Ord (should get eliminated during simplification)
      | Cmp CmpOp ty e e
      -- Idx (survives simplification, because we allow it to be backend-dependent)
      | IntAsIndex ty e
      | IndexAsInt e
      | IdxSetSize ty
        deriving (Show, Eq, Generic)

data PrimEffect e = MAsk | MTell e | MGet | MPut e
    deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

data VSpaceOp e = VZero | VAdd e e deriving (Show, Eq, Generic)
data ScalarBinOp = IAdd | ISub | IMul | IDiv | ICmp CmpOp
                 | FAdd | FSub | FMul | FDiv | FCmp CmpOp | Pow
                 | And | Or | Rem
                   deriving (Show, Eq, Generic)

data ScalarUnOp = Not | FNeg | IntToReal | BoolToInt | UnsafeIntToBool
                  deriving (Show, Eq, Generic)

data CmpOp = Less | Greater | Equal | LessEqual | GreaterEqual
             deriving (Show, Eq, Generic)

data Direction = Fwd | Rev  deriving (Show, Eq, Generic)

type PrimName = PrimExpr () () ()

builtinNames :: M.Map String PrimName
builtinNames = M.fromList
  [ ("iadd", binOp IAdd), ("isub", binOp ISub)
  , ("imul", binOp IMul), ("fdiv", binOp FDiv)
  , ("fadd", binOp FAdd), ("fsub", binOp FSub)
  , ("fmul", binOp FMul), ("idiv", binOp IDiv)
  , ("pow" , binOp Pow ), ("rem" , binOp Rem )
  , ("and" , binOp And ), ("or"  , binOp Or  ), ("not" , unOp  Not )
  , ("fneg", unOp  FNeg)
  , ("inttoreal", unOp IntToReal)
  , ("booltoint", unOp BoolToInt)
  , ("asint"           , OpExpr $ IndexAsInt ())
  , ("idxSetSize"      , OpExpr $ IdxSetSize ())
  , ("linearize"       , OpExpr $ Linearize ())
  , ("linearTranspose" , OpExpr $ Transpose ())
  , ("asidx"           , OpExpr $ IntAsIndex () ())
  , ("vzero"           , OpExpr $ VSpaceOp () $ VZero)
  , ("vadd"            , OpExpr $ VSpaceOp () $ VAdd () ())
  , ("newtypecast"     , OpExpr $ NewtypeCast () ())
  , ("select"          , OpExpr $ Select () () () ())
  , ("runReader"       , OpExpr $ RunReader () ())
  , ("runWriter"       , OpExpr $ RunWriter    ())
  , ("runState"        , OpExpr $ RunState  () ())
  , ("indexReader"     , OpExpr $ IndexEff Reader () () ())
  , ("indexWriter"     , OpExpr $ IndexEff Writer () () ())
  , ("indexState"      , OpExpr $ IndexEff State  () () ())
  , ("todo"       , ConExpr $ Todo ())
  , ("ask"        , OpExpr $ PrimEffect () $ MAsk)
  , ("tell"       , OpExpr $ PrimEffect () $ MTell ())
  , ("get"        , OpExpr $ PrimEffect () $ MGet)
  , ("put"        , OpExpr $ PrimEffect () $ MPut  ())
  , ("inject"     , OpExpr $ Inject ())
  , ("Int"    , TyExpr $ BaseType IntType)
  , ("Real"   , TyExpr $ BaseType RealType)
  , ("Bool"   , TyExpr $ BaseType BoolType)
  , ("TyKind" , TyExpr $ TypeKind)
  , ("IntRange", TyExpr $ IntRange () ())
  , ("TabType" , TyExpr $ TabTypeCon ())
  ]
  where
    binOp op = OpExpr $ ScalarBinOp op () ()
    unOp  op = OpExpr $ ScalarUnOp  op ()

strToName :: String -> Maybe PrimName
strToName s = M.lookup s builtinNames

nameToStr :: PrimName -> String
nameToStr prim = case lookup prim $ map swap $ M.toList builtinNames of
  Just s  -> s
  Nothing -> show prim

-- === top-level constructs ===

data SourceBlock = SourceBlock
  { sbLine     :: Int
  , sbOffset   :: Int
  , sbText     :: String
  , sbContents :: SourceBlock'
  , sbId       :: Maybe BlockId }  deriving (Show)

type BlockId = Int
type ReachedEOF = Bool
data SourceBlock' = RunModule UModule
                  | Command CmdName (Name, UModule)
                  | GetNameType Var
                  | IncludeSourceFile String
                  | LoadData Pat DataFormat String
                  | ProseBlock String
                  | CommentLine
                  | EmptyLines
                  | UnParseable ReachedEOF String
                    deriving (Show, Eq, Generic)

data CmdName = GetType | ShowPasses | ShowPass PassName
             | TimeIt | EvalExpr OutFormat | Dump DataFormat String
                deriving  (Show, Eq, Generic)

addBlockId :: BlockId -> SourceBlock -> SourceBlock
addBlockId bid block = block {sbContents = contents', sbId = Just bid}
  where
    contents' = case sbContents block of
      -- TODO: add blockId here if we end up needing it
      contents -> contents

addBlockIdModule :: BlockId -> ModuleP body -> ModuleP body
addBlockIdModule bid (Module _ ty body) = Module (Just bid) ty body

-- === imperative IR ===

-- TODO: add args
data ImpFunction = ImpFunction [IVar] [IVar] ImpProg  -- destinations first
                   deriving (Show, Eq)
newtype ImpProg = ImpProg [ImpStatement]
                  deriving (Show, Eq, Generic, Semigroup, Monoid)
type ImpStatement = (Maybe IVar, ImpInstr)

data ImpInstr = Load  IExpr
              | Store IExpr IExpr  -- destination first
              | Copy  IExpr IExpr  -- destination first
              | Alloc IArrayType
              | Free IVar
              | IGet IExpr Index
              | Loop Direction IVar Size ImpProg
              | IPrimOp IPrimOp
                deriving (Show, Eq)

data IExpr = ILit LitVal
           | IVar IVar
             deriving (Show, Eq)

type IPrimOp = PrimOp BaseType IExpr ()
type IVal = IExpr  -- only ILit and IRef constructors
type IVar = VarP IType
data IType = IValType BaseType
           | IRefType IArrayType
              deriving (Show, Eq)

type IArrayType = (BaseType, [Size])

type Size  = IExpr
type Index = IExpr

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


-- === Environment for type and kind checking ===

data JointTypeEnv = JointTypeEnv { namedEnv :: TypeEnv, deBruijnEnv :: [Type] }

fromNamedEnv :: TypeEnv -> JointTypeEnv
fromNamedEnv env = JointTypeEnv env []

jointEnvLookup :: JointTypeEnv -> VarP ann -> Maybe Type
jointEnvLookup jenv v = case varName v of
  DeBruijn idx -> Just $ deBruijnEnv jenv !! idx
  _            -> envLookup (namedEnv jenv) v

jointEnvGet :: JointTypeEnv -> VarP ann -> Type
jointEnvGet jenv v = fromJust $ jointEnvLookup jenv v

extendNamed :: MonadReader JointTypeEnv m => TypeEnv -> m a -> m a
extendNamed env m = local (\jenv -> jenv { namedEnv = namedEnv jenv <> env }) m

extendDeBruijn :: MonadReader JointTypeEnv m => Type -> m a -> m a
extendDeBruijn t m = local (\jenv -> jenv { deBruijnEnv = t : deBruijnEnv jenv }) m

-- === passes ===

data PassName = Parse | TypePass | NormPass | SimpPass | ImpPass | JitPass
              | Flops | LLVMOpt | AsmPass | JAXPass | JAXSimpPass | LLVMEval
              | JaxprAndHLO
                deriving (Ord, Eq, Bounded, Enum)

passNameMap :: M.Map String PassName
passNameMap = buildNameMap

parsePassName :: String -> Maybe PassName
parsePassName s = M.lookup s passNameMap

instance Show PassName where
  show p = case p of
    Parse    -> "parse" ; TypePass -> "typed"   ; NormPass -> "norm"
    SimpPass -> "simp"  ; ImpPass  -> "imp"     ; JitPass  -> "llvm"
    Flops    -> "flops" ; LLVMOpt  -> "llvmopt" ; AsmPass  -> "asm"
    JAXPass  -> "jax"   ; JAXSimpPass -> "jsimp";
    LLVMEval -> "llvmeval" ; JaxprAndHLO -> "jaxprhlo";

-- TODO: consider using this for builtins too
buildNameMap :: (Show a, Enum a, Bounded a) => M.Map String a
buildNameMap = M.fromList [(show x, x) | x <- [minBound..maxBound]]

-- === outputs ===

type LitProg = [(SourceBlock, Result)]
type SrcCtx = Maybe SrcPos
data Result = Result [Output] (Except ())  deriving (Show, Eq)

data Output = TextOut String
            | HeatmapOut Int Int (V.Vector Double)
            | ScatterOut (V.Vector Double) (V.Vector Double)
            | PassInfo PassName String
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
             | NotImplementedErr
             | DataIOErr
             | MiscErr
  deriving (Show, Eq)

type Except a = Either Err a

throw :: MonadError Err m => ErrType -> String -> m a
throw e s = throwError $ Err e Nothing s

throwIf :: MonadError Err m => Bool -> ErrType -> String -> m ()
throwIf True  e s = throw e s
throwIf False _ _ = return ()

modifyErr :: MonadError e m => m a -> (e -> e) -> m a
modifyErr m f = catchError m $ \e -> throwError (f e)

addContext :: MonadError Err m => String -> m a -> m a
addContext s m = modifyErr m $ \(Err e p s') -> Err e p (s' ++ s)

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

-- === substitutions ===

type Vars = TypeEnv

bind :: VarP a -> Env a
bind v@(_:>ty) = v @> ty

newEnv :: [VarP ann] -> [a] -> Env a
newEnv vs xs = fold $ zipWith (@>) vs xs

class HasVars a where
  freeVars :: a -> Vars

instance HasVars UExpr where
  freeVars (UPos _ e) = freeVars e

instance HasVars UExpr' where
  freeVars expr = case expr of
    UVar v -> uVarFreeVars v
    ULam _ lam -> freeVars lam
    UFor _ lam -> freeVars lam
    UApp _ f x -> freeVars f <> freeVars x
    UArrow _ piTy -> freeVars piTy
    UDecl decl body ->
      freeVars decl <> (freeVars body `envDiff` uDeclBoundVars decl)
    UAnnot expr ann -> freeVars expr <> freeVars ann
    _ -> mempty

instance HasVars UDecl where
  freeVars (ULet p expr) = foldMap uBinderFreeVars p <> freeVars expr

instance HasVars ULamExpr where
  freeVars (ULamExpr p expr) =
    foldMap uBinderFreeVars p <> (freeVars expr `envDiff` foldMap (@>()) p)

instance HasVars UPiType where
  freeVars (UPi v@(_:>ann) b) = freeVars ann <> (freeVars b `envDiff` (v@>()))

uDeclBoundVars :: UDecl -> Scope
uDeclBoundVars (ULet p _) = foldMap (@>Nothing) p

uBinderFreeVars :: UBinder -> Vars
uBinderFreeVars (_:>ann) = foldMap freeVars ann

uVarFreeVars :: UVar -> Vars
uVarFreeVars (DeBruijn _ :> ann) = freeVars ann
uVarFreeVars v@(_:>ann) = v @> UnitTy <> freeVars ann

nameAsEnv :: Name -> Vars
nameAsEnv v = (v:>())@>UnitTy

sourceBlockBoundVars :: SourceBlock -> Vars
sourceBlockBoundVars block = case sbContents block of
  RunModule (UModule _ vs _) -> foldMap nameAsEnv vs
  -- LoadData p _ _             -> foldMap nameAsEnv p
  _                          -> mempty

instance HasVars b => HasVars (PiType b) where
  freeVars (Pi a b) = freeVars a <> freeVars b

-- NOTE: We don't have an instance for VarP, because it's used to represent
--       both binders and regular variables, but each requires different treatment
freeBinderTypeVars :: Var -> Vars
freeBinderTypeVars (_ :> t) = freeVars t

varFreeVars :: Var -> Vars
varFreeVars (DeBruijn _ :> t) = freeVars t
varFreeVars v@(_ :> t) = bind v <> freeVars t

instance HasVars () where
  freeVars () = mempty

instance (HasVars a, HasVars b) => HasVars (a, b) where
  freeVars (x, y) = freeVars x <> freeVars y

instance HasVars SourceBlock where
  freeVars block = case sbContents block of
    RunModule (   UModule vs _ _) -> foldMap nameAsEnv vs
    Command _ (_, UModule vs _ _) -> foldMap nameAsEnv vs
    GetNameType v                     -> v @> varAnn v
    _ -> mempty

instance HasVars Expr where
  freeVars expr = case expr of
    Decl decl body -> freeVars decl <> (freeVars body `envDiff` declBoundVars decl)
    CExpr primop   -> freeVars primop
    Atom atom      -> freeVars atom

declBoundVars :: Decl -> Env ()
declBoundVars (Let b _) = b@>()

instance HasVars LamExpr where
  freeVars (LamExpr b body) =
    freeBinderTypeVars b <> (freeVars body `envDiff` (b@>()))

instance HasVars Atom where
  freeVars atom = case atom of
    Var v -> varFreeVars v
    Con con   -> freeVars con
    ArrowType _ l p -> freeVars l <> freeVars p
    TabType p -> freeVars p
    Effect row tailVar ->  foldMap (varFreeVars . \(v, (_,t)) -> v:>t) (envPairs row)
                        <> foldMap freeVars tailVar
    NoAnn -> mempty
    TC con -> execWriter $ traverseTyCon con (\t -> t <$ tell (freeVars t))
                                             (\e -> e <$ tell (freeVars e))

instance HasVars Decl where
  freeVars (Let bs expr) = foldMap freeVars bs <> freeVars expr

instance HasVars a => HasVars (Env a) where
  freeVars env = foldMap freeVars env

instance HasVars TopEnv where
  freeVars (TopEnv e1 e2 e3) = freeVars e1 <> freeVars e2 <> freeVars e3

instance (HasVars a, HasVars b) => HasVars (Either a b)where
  freeVars (Left  x) = freeVars x
  freeVars (Right x) = freeVars x

fmapExpr :: TraversableExpr expr
         => expr ty e lam
         -> (ty  -> ty')
         -> (e   -> e')
         -> (lam -> lam')
         -> expr ty' e' lam'
fmapExpr e fT fE fL =
  runIdentity $ traverseExpr e (return . fT) (return . fE) (return . fL)

class TraversableExpr expr where
  traverseExpr :: Applicative f
               => expr ty e lam
               -> (ty  -> f ty')
               -> (e   -> f e')
               -> (lam -> f lam')
               -> f (expr ty' e' lam')

instance TraversableExpr PrimExpr where
  traverseExpr (OpExpr  e) fT fE fL = OpExpr  <$> traverseExpr e fT fE fL
  traverseExpr (ConExpr e) fT fE fL = ConExpr <$> traverseExpr e fT fE fL
  traverseExpr (TyExpr  e) fT fE _  = TyExpr  <$> traverseTyCon e fT fE

instance TraversableExpr PrimOp where
  traverseExpr primop fT fE fL = case primop of
    App l e1 e2          -> liftA3 App (fT l) (fE e1) (fE e2)
    TApp e tys           -> liftA2 TApp (fE e) (traverse fT tys)
    For d lam            -> liftA  (For d) (fL lam)
    TabCon n ty xs       -> liftA3 TabCon (fT n) (fT ty) (traverse fE xs)
    TabGet e i           -> liftA2 TabGet (fE e) (fE i)
    SumCase e l r        -> liftA3 SumCase (fE e) (fL l) (fL r)
    RecGet e i           -> liftA2 RecGet (fE e) (pure i)
    SumGet e s           -> liftA2 SumGet (fE e) (pure s)
    SumTag e             -> liftA  SumTag (fE e)
    ArrayGep e i         -> liftA2 ArrayGep (fE e) (fE i)
    LoadScalar e         -> liftA  LoadScalar (fE e)
    ScalarBinOp op e1 e2 -> liftA2 (ScalarBinOp op) (fE e1) (fE e2)
    ScalarUnOp  op e     -> liftA  (ScalarUnOp  op) (fE e)
    VSpaceOp ty VZero    -> liftA2 VSpaceOp (fT ty) (pure VZero)
    VSpaceOp ty (VAdd e1 e2) -> liftA2 VSpaceOp (fT ty) (liftA2 VAdd (fE e1) (fE e2))
    Cmp op ty e1 e2      -> liftA3 (Cmp op) (fT ty) (fE e1) (fE e2)
    Select ty p x y      -> liftA3 Select (fT ty) (fE p) (fE x) <*> fE y
    PrimEffect ref m     -> liftA2 PrimEffect (fE ref) $ case m of
       MAsk    -> pure  MAsk
       MTell e -> liftA MTell (fE e)
       MGet    -> pure  MGet
       MPut  e -> liftA MPut  (fE e)
    RunReader r  lam    -> liftA2 RunReader (fE r ) (fL lam)
    RunWriter    lam    -> liftA  RunWriter         (fL lam)
    RunState  s  lam    -> liftA2 RunState  (fE s ) (fL lam)
    IndexEff eff ref i lam -> liftA3 (IndexEff eff) (fE ref) (fE i) (fL lam)
    Linearize lam        -> liftA  Linearize (fL lam)
    Transpose lam        -> liftA  Transpose (fL lam)
    IntAsIndex ty e      -> liftA2 IntAsIndex (fT ty) (fE e)
    IndexAsInt e         -> liftA  IndexAsInt (fE e)
    IdxSetSize ty        -> liftA  IdxSetSize (fT ty)
    NewtypeCast ty e     -> liftA2 NewtypeCast (fT ty) (fE e)
    FFICall s argTys ansTy args ->

      liftA3 (FFICall s) (traverse fT argTys) (fT ansTy) (traverse fE args)
    Inject e             -> liftA Inject (fE e)

instance TraversableExpr PrimCon where
  traverseExpr op fT fE fL = case op of
    Lit l        -> pure $ Lit l
    ArrayLit arr -> pure $ ArrayLit arr
    Lam im lin eff lam -> liftA3 (Lam im) (fT lin) (fT eff) (fL lam)
    AFor n e     -> liftA2 AFor (fT n) (fE e)
    AGet e       -> liftA  AGet (fE e)
    AsIdx n e    -> liftA2 AsIdx (fT n) (fE e)
    AnyValue t   -> AnyValue <$> fT t
    SumCon c l r -> SumCon <$> fE c <*> fE l <*> fE r
    RecCon r     -> liftA  RecCon (traverse fE r)
    Todo ty      -> liftA  Todo (fT ty)

instance (TraversableExpr expr, HasVars ty, HasVars e, HasVars lam)
         => HasVars (expr ty e lam) where
  freeVars expr = execWriter $
    traverseExpr expr (tell . freeVars) (tell . freeVars) (tell . freeVars)

unzipExpr :: TraversableExpr expr
          => expr ty e lam -> (expr () () (), ([ty], [e], [lam]))
unzipExpr expr = (blankExpr, xs)
  where
    blankExpr = fmapExpr expr (const ()) (const ()) (const ())
    xs = execWriter $ traverseExpr expr
            (\ty  -> tell ([ty], [] , []   ))
            (\e   -> tell ([]  , [e], []   ))
            (\lam -> tell ([]  , [] , [lam]))

instance RecTreeZip Type where
  recTreeZip (RecTree r) (TC (RecType r')) = RecTree $ recZipWith recTreeZip r r'
  recTreeZip (RecLeaf x) x' = RecLeaf (x, x')
  recTreeZip (RecTree _) _ = error "Bad zip"

instance Semigroup TopEnv where
  TopEnv e1 e2 e3 <> TopEnv e1' e2' e3'=
    TopEnv (e1 <> e1') (e2 <> e2') (e3 <> e3')

instance Monoid TopEnv where
  mempty = TopEnv mempty mempty mempty

instance Eq SourceBlock where
  x == y = sbText x == sbText y

instance Ord SourceBlock where
  compare x y = compare (sbText x) (sbText y)

traverseTyCon :: Applicative m
              => TyCon ty e -> (ty -> m ty') -> (e -> m e') -> m (TyCon ty' e')
traverseTyCon con fTy fE = case con of
  BaseType b        -> pure $ BaseType b
  IntRange a b      -> liftA2 IntRange (fE a) (fE b)
  IndexRange t a b  -> liftA3 IndexRange (fTy t) (traverse fE a) (traverse fE b)
  ArrayType t       -> pure $ ArrayType t
  SumType (l, r)    -> liftA SumType $ liftA2 (,) (fTy l) (fTy r)
  RecType r         -> liftA RecType $ traverse fTy r
  RefType t         -> liftA RefType (fTy t)
  TabTypeCon t      -> liftA TabTypeCon (fTy t)
  TypeApp t xs      -> liftA2 TypeApp (fTy t) (traverse fTy xs)
  LinCon            -> pure LinCon
  NonLinCon         -> pure NonLinCon
  TypeKind          -> pure TypeKind
  ArrowKind as b    -> liftA2 ArrowKind (traverse fTy as) (fTy b)
  MultKind          -> pure MultKind
  EffectKind        -> pure EffectKind

fmapTyCon :: TyCon ty e -> (ty -> ty') -> (e -> e') -> TyCon ty' e'
fmapTyCon con fT fE = runIdentity $ traverseTyCon con (return . fT) (return . fE)

-- === Synonyms ===

infixr 1 -->
infixr 1 --@
infixr 2 ==>

(-->) :: Type -> Type -> Type
a --> b = ArrowType Expl NonLin $ Pi a (noEffect, b)

(--@) :: Type -> Type -> Type
a --@ b = ArrowType Expl Lin $ Pi a (noEffect, b)

(==>) :: Type -> Type -> Type
a ==> b = TabType $ Pi a b

pattern IntVal :: Int -> Atom
pattern IntVal x = Con (Lit (IntLit x))

pattern RealVal :: Double -> Atom
pattern RealVal x = Con (Lit (RealLit x))

pattern BoolVal :: Bool -> Atom
pattern BoolVal x = Con (Lit (BoolLit x))

pattern RecVal :: Record Atom -> Atom
pattern RecVal r = Con (RecCon r)

pattern SumVal :: Atom -> Atom -> Atom -> Atom
pattern SumVal t l r = Con (SumCon t l r)

pattern TupVal :: [Atom] -> Atom
pattern TupVal xs = RecVal (Tup xs)

pattern PairVal :: Atom -> Atom -> Atom
pattern PairVal x y = TupVal [x, y]

pattern PairTy :: Type -> Type -> Type
pattern PairTy x y = TC (RecType (Tup [x, y]))

pattern TupTy :: [Type] -> Type
pattern TupTy xs = TC (RecType (Tup xs))

pattern UnitVal :: Atom
pattern UnitVal = TupVal []

pattern UnitTy :: Type
pattern UnitTy = TupTy []

pattern TabTy :: Type -> Type -> Type
pattern TabTy a b = TabType (Pi a b)

pattern ArrayTy :: [Int] -> BaseType -> Type
pattern ArrayTy shape b = TC (ArrayType (shape, b))

pattern BaseTy :: BaseType -> Type
pattern BaseTy b = TC (BaseType b)

pattern RecTy :: Record Type -> Type
pattern RecTy a = TC (RecType a)

pattern SumTy :: Type -> Type -> Type
pattern SumTy l r = TC (SumType (l, r))

pattern RefTy :: Type -> Type
pattern RefTy a = TC (RefType a)

pattern NonLin :: Type
pattern NonLin = TC NonLinCon

pattern Lin :: Type
pattern Lin = TC LinCon

pattern IntTy :: Type
pattern IntTy = TC (BaseType IntType)

pattern BoolTy :: Type
pattern BoolTy = TC (BaseType BoolType)

pattern RealTy :: Type
pattern RealTy = TC (BaseType RealType)

pattern TyKind :: Kind
pattern TyKind = TC TypeKind

pattern FixedIntRange :: Int -> Int -> Type
pattern FixedIntRange low high = TC (IntRange (IntVal low) (IntVal high))

-- TODO: Enable once https://gitlab.haskell.org//ghc/ghc/issues/13363 is fixed...
-- {-# COMPLETE TypeVar, ArrowType, TabTy, Forall, TypeAlias, Effect, NoAnn, TC #-}
