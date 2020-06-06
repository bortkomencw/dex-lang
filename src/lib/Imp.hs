-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Imp (toImpFunction, impExprToAtom, impExprType, impTypeToArrayType) where

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Except hiding (Except)
import Control.Monad.State
import Control.Monad.Writer
import Data.Foldable
import Data.Functor.Reverse
import Data.Text.Prettyprint.Doc

import Syntax
import Env
import Type
import PPrint
import Cat
import Record

type EmbedEnv = ([IVar], (Scope, ImpProg))
type ImpM = Cat EmbedEnv

toImpFunction :: ([Var], Block) -> ImpFunction
toImpFunction (vsIn, expr) = runImpM $ do
  (outDest, vsOut) <- makeDest "out" $ getType expr
  ((), prog) <- scopedBlock $ do
    ans <- toImpBlock mempty expr
    copyAtom outDest ans
  let vsIn' = map (fmap typeToIType) vsIn
  return $ ImpFunction vsOut vsIn' prog

runImpM :: ImpM a -> a
runImpM m = fst $ runCat m mempty

toImpBlock :: SubstEnv -> Block -> ImpM Atom
toImpBlock env (Block decls result) = do
  env' <- catFoldM toImpDecl env decls
  toImpExpr (env <> env') result

toImpDecl ::  SubstEnv -> Decl -> ImpM SubstEnv
toImpDecl env (Let b bound) = do
  b' <- traverse (impSubst env) b
  ans <- toImpExpr env bound
  return $ b' @> ans

toImpExpr :: SubstEnv -> Expr -> ImpM Atom
toImpExpr env expr = case expr of
  App x i -> case getType x of
    TabTy _ _ -> do
      x' <- impSubst env x
      i' <- impSubst env i
      impTabGet x' i'
    _ -> error $ "shouldn't have non-table app left"
  Atom x   -> impSubst env x
  Op   op  -> toImpOp =<< traverse (impSubst env) op
  Hof  hof -> toImpHof env hof

impSubst :: HasVars a => SubstEnv -> a -> ImpM a
impSubst env x = do
  scope <- looks (fst . snd)
  return $ subst (env, scope) x

toImpOp :: PrimOp Atom -> ImpM Atom
toImpOp op = case op of
  TabCon (TabTy n _) rows -> do
    dest <- alloc resultTy
    forM_ (zip [0..] rows) $ \(i, row) -> do
      i' <- intToIndex n $ IIntVal i
      ithDest <- impTabGet dest i'
      copyAtom ithDest row
    return dest
  SumGet x getLeft ->
    case x of
      SumVal _ l r -> return $ if getLeft then l else r
      val -> error $ "Expected a sum type, got: " ++ pprint val
  SumTag x ->
    case x of
      SumVal t _ _ -> return t
      val -> error $ "Expected a sum type, got: " ++ pprint val
  RecGet x i -> do
    case x of
      RecVal r -> return $ recGet r i
      val -> error $ "Expected a record, got: " ++ pprint val
  Fst ~(PairVal x _) -> return x
  Snd ~(PairVal _ y) -> return y
  PrimEffect ~(Con (RefCon _ ref)) m -> do
    case m of
      MAsk    -> return ref
      MTell x -> addToAtom ref x >> return UnitVal
      MPut x  -> copyAtom  ref x >> return UnitVal
      MGet -> do
        dest <- alloc resultTy
        copyAtom dest ref
        return dest
  IntAsIndex n i -> do
    i' <- fromScalarAtom i
    n' <- indexSetSize n
    ans <- emitInstr $ IPrimOp $
             FFICall "int_to_index_set" [IntType, IntType] IntType [i', n']
    return $ toScalarAtom resultTy ans
  Cmp _ _ _ _ -> error $ "All instances of Cmp should get resolved in simplification"
  IdxSetSize n -> liftM (toScalarAtom resultTy) $ indexSetSize n
  IndexAsInt i -> toScalarAtom IntTy <$> indexToInt (getType i) i
  Inject e -> do
    let rt@(TC (IndexRange t low _)) = getType e
    offset <- case low of
      InclusiveLim a -> indexToInt t a
      ExclusiveLim a -> indexToInt t a >>= impAdd IOne
      Unlimited      -> return IZero
    restrictIdx <- indexToInt rt e
    idx <- impAdd restrictIdx offset
    intToIndex t idx
  _ -> do
    op' <- traverse fromScalarAtom op
    toScalarAtom resultTy <$> emitInstr (IPrimOp op')
  where
    resultTy :: Type
    resultTy = getType $ Op op

toImpHof :: SubstEnv -> Hof -> ImpM Atom
toImpHof env hof = case hof of
  For d (Lam (Abs b@(_:>idxTy) (_, body))) -> do
    idxTy' <- impSubst env idxTy
    n' <- indexSetSize idxTy'
    dest <- alloc resultTy
    emitLoop d n' $ \i -> do
      i' <- intToIndex idxTy i
      ithDest <- impTabGet dest i'
      ans <- toImpBlock (env <> b @> i') body
      copyAtom ithDest ans
    return dest
--   RunReader r (Abs ref body, env) -> do
--     toImpBlock (env <> ref @> r) body
--   RunWriter (Abs ref body, env) -> do
--     wDest <- alloc wTy
--     initializeAtomZero wDest
--     aResult <- toImpBlock (env <> ref @> wDest) body
--     return $ PairVal aResult wDest
--     where (PairTy _ wTy) = resultTy
  RunState s (BinaryFunVal region ref _ body) -> do
    s' <- impSubst env s
    sDest <- alloc sTy
    copyAtom sDest s'
    aResult <- toImpBlock (env <> ref @> Con (RefCon (Var region) sDest)) body
    return $ PairVal aResult sDest
    where (PairTy _ sTy) = resultTy
  where
    resultTy :: Type
    resultTy = getType $ Hof hof

toScalarAtom :: Type -> IExpr -> Atom
toScalarAtom _  (ILit v) = Con $ Lit v
toScalarAtom ty x@(IVar (v:>_)) = case ty of
  BaseTy _                -> Var (v:>ty)
  TC (IntRange       _ _) -> Con $ AsIdx ty $ toScalarAtom IntTy x
  TC (IndexRange ty' _ _) -> Con $ AsIdx ty $ toScalarAtom ty' x
  _ -> error $ "Not a scalar type: " ++ pprint ty

anyValue :: Type -> IExpr
anyValue (TC (BaseType RealType))   = ILit $ RealLit 1.0
anyValue (TC (BaseType IntType))    = ILit $ IntLit 1
anyValue (TC (BaseType BoolType))   = ILit $ BoolLit False
anyValue (TC (BaseType StrType))    = ILit $ StrLit ""
-- XXX: This is not strictly correct, because those types might not have any
--      inhabitants. We might want to consider emitting some run-time code that
--      aborts the program if this really ends up being the case.
anyValue (TC (IntRange _ _))        = ILit $ IntLit 0
anyValue (TC (IndexRange _ _ _))    = ILit $ IntLit 0
anyValue t = error $ "Expected a scalar type in anyValue, got: " ++ pprint t

fromScalarAtom :: Atom -> ImpM IExpr
fromScalarAtom atom = case atom of
  Var (v:>ty)       -> return $ IVar (v :> typeToIType ty)
  Con (Lit x)       -> return $ ILit x
  Con (AGet x)      -> load (fromArrayAtom x)
  Con (AsIdx _ x)   -> fromScalarAtom x
  Con (AnyValue ty) -> return $ anyValue ty
  _ -> error $ "Expected scalar, got: " ++ pprint atom

fromArrayAtom :: Atom -> IExpr
fromArrayAtom atom = case atom of
  Var (v:>ty)          -> IVar (v :> typeToIType ty)
  _ -> error $ "Expected array, got: " ++ pprint atom

-- TODO: free!
alloc :: Type -> ImpM Atom
alloc ty = do
  (dest, vs) <- makeDest "v" ty
  flip mapM_ vs $ \v@(_:>IRefType refTy) -> emitStatement (Just v, Alloc refTy)
  extend $ asFst vs
  return dest

makeDest :: Name-> Type -> ImpM (Atom, [IVar])
makeDest name ty = runWriterT $ makeDest' name [] ty

makeDest' :: Name-> [IExpr] -> Type -> WriterT [IVar] ImpM Atom
makeDest' name shape (TabTy n b) = do
  n'  <- lift $ indexSetSize n
  liftM (Con . AFor n) $ makeDest' name (shape ++ [n']) b
makeDest' name shape ty@(TC con) = case con of
  BaseType b  -> do
    v <- lift $ freshVar (name :> IRefType (b, shape))
    tell [v]
    return $ Con $ AGet $ Var (fmap impTypeToType v)
  RecType r   -> liftM RecVal $ traverse (makeDest' name shape) r
  PairType a b -> PairVal <$> makeDest' name shape a <*> makeDest' name shape b
  UnitType -> return UnitVal
  IntRange   _ _   -> scalarIndexSet ty
  IndexRange _ _ _ -> scalarIndexSet ty
  _ -> error $ "Can't lower type to imp: " ++ pprint con
  where
    scalarIndexSet t = liftM (Con . AsIdx t) $ makeDest' name shape (BaseTy IntType)
makeDest' _ _ ty = error $ "Can't lower type to imp: " ++ pprint ty

impTabGet :: Atom -> Atom -> ImpM Atom
impTabGet ~(Con (AFor it body)) i = do
  i' <- indexToInt it i
  flip traverseLeaves body $ \(~(Con (AGet arr))) -> do
    ans <- emitInstr $ IGet (fromArrayAtom arr) i'
    return $ Con $ AGet $ impExprToAtom ans

intToIndex :: Type -> IExpr -> ImpM Atom
intToIndex ty@(TC con) i = case con of
  IntRange _ _      -> iAsIdx
  IndexRange _ _ _  -> iAsIdx
  BaseType BoolType -> impExprToAtom <$> emitUnOp UnsafeIntToBool i
  RecType r -> do
    strides <- getStrides $ fmap (\t->(t,t)) r
    liftM RecVal $
      flip evalStateT i $ forM strides $ \(ty', _, stride) -> do
        i' <- get
        iCur  <- lift $ impDiv i' stride
        iRest <- lift $ impRem i' stride
        put iRest
        lift $ intToIndex ty' iCur
  SumType (l, r) -> do
    ls <- indexSetSize l
    isLeft <- impCmp Less i ls
    li <- intToIndex l i
    ri <- intToIndex r =<< impSub i ls
    return $ Con $ SumCon (toScalarAtom BoolTy isLeft) li ri
  _ -> error $ "Unexpected type " ++ pprint con
  where
    iAsIdx = return $ Con $ AsIdx ty $ impExprToAtom i
intToIndex ty _ = error $ "Unexpected type " ++ pprint ty

indexToInt :: Type -> Atom -> ImpM IExpr
indexToInt ty idx = case ty of
  BoolTy  -> emitUnOp BoolToInt =<< fromScalarAtom idx
  RecTy rt -> do
    case idx of
      (RecVal rv) -> do
        rWithStrides <- getStrides $ recZipWith (,) rv rt
        foldrM f (IIntVal 0) rWithStrides
        where
        f :: (Atom, Type, IExpr) -> IExpr -> ImpM IExpr
        f (i, it, stride) cumIdx = do
          i' <- indexToInt it i
          iDelta  <- impMul i' stride
          impAdd cumIdx iDelta
      _ -> error $ "Expected a record, got: " ++ pprint idx
  SumTy lType rType     -> do
    case idx of
      (SumVal con lVal rVal) -> do
        lTypeSize <- indexSetSize lType
        lInt <- indexToInt lType lVal
        rInt <- impAdd lTypeSize =<< indexToInt rType rVal
        conExpr <- fromScalarAtom con
        impSelect conExpr lInt rInt
      _ -> error $ "Expected a sum constructor, got: " ++ pprint idx
  TC (IntRange _ _)     -> fromScalarAtom idx
  TC (IndexRange _ _ _) -> fromScalarAtom idx
  _ -> error $ "Unexpected type " ++ pprint ty

getStrides :: Traversable f => f (a, Type) -> ImpM (f (a, Type, IExpr))
getStrides xs =
  liftM getReverse $ flip evalStateT (IIntVal 1) $
    forM (Reverse xs) $ \(x, ty) -> do
      stride  <- get
      size    <- lift $ indexSetSize ty
      stride' <- lift $ impMul stride size
      put stride'
      return (x, ty, stride)

impExprToAtom :: IExpr -> Atom
impExprToAtom e = case e of
  IVar (v:>ty) -> Var (v:> impTypeToType ty)
  ILit x       -> Con $ Lit x

-- TODO: pick a single convention for order of (BaseType, Shape) pair
impTypeToArrayType :: IType -> ArrayType
impTypeToArrayType (IRefType (b, shape)) = (map fromILitInt shape, b)
impTypeToArrayType _ = error "Not an array type"

fromILitInt :: IExpr -> Int
fromILitInt (ILit (IntLit x)) = x
fromILitInt expr = error $ "Not an int: " ++ pprint expr

impTypeToType :: IType -> Type
impTypeToType (IValType  b        ) = BaseTy         b
impTypeToType (IRefType (b, shape)) = ArrayTy shape' b
  where shape' = map (\(IIntVal n) -> n) shape

typeToIType :: Type -> IType
typeToIType ty = case ty of
  BaseTy        b -> IValType b
  ArrayTy shape b -> IRefType (b, map IIntVal shape)
  _ -> error $ "Not a valid Imp type: " ++ pprint ty

toImpBaseType :: Type -> BaseType
toImpBaseType (TabTy _ a) = toImpBaseType a
toImpBaseType (TC con) = case con of
  BaseType b       -> b
  IntRange _ _     -> IntType
  IndexRange _ _ _ -> IntType
  _ -> error $ "Unexpected type: " ++ pprint con
toImpBaseType ty = error $ "Unexpected type: " ++ pprint ty

indexSetSize :: Type -> ImpM IExpr
indexSetSize (TC con) = case con of
  IntRange low high -> do
    low'  <- fromScalarAtom low
    high' <- fromScalarAtom high
    impSub high' low'
  IndexRange n low high -> do
    low' <- case low of
      InclusiveLim x -> indexToInt n x
      ExclusiveLim x -> indexToInt n x >>= impAdd IOne
      Unlimited      -> return IZero
    high' <- case high of
      InclusiveLim x -> indexToInt n x >>= impAdd IOne
      ExclusiveLim x -> indexToInt n x
      Unlimited      -> indexSetSize n
    impSub high' low'
  RecType r -> do
    sizes <- traverse indexSetSize r
    impProd $ toList sizes
  BaseType BoolType -> return $ IIntVal 2
  SumType (l, r) -> do
    ls <- indexSetSize l
    rs <- indexSetSize r
    impAdd ls rs
  _ -> error $ "Not implemented " ++ pprint con
indexSetSize ty = error $ "Not implemented " ++ pprint ty

traverseLeaves :: Applicative f => (Atom -> f Atom) -> Atom -> f Atom
traverseLeaves f atom = case atom of
  Var _        -> f atom
  Con (Lit  _) -> f atom
  Con (AGet _) -> f atom
  Con destCon -> liftA Con $ case destCon of
    AsIdx n idx -> liftA (AsIdx n) $ recur idx
    AFor n body -> liftA (AFor  n) $ recur body
    RecCon r    -> liftA RecCon    $ traverse recur r
    PairCon x y -> liftA2 PairCon (recur x) (recur y)
    UnitCon     -> pure UnitCon
    _ -> error $ "Not a valid Imp atom: " ++ pprint atom
  _ ->   error $ "Not a valid Imp atom: " ++ pprint atom
  where recur = traverseLeaves f

leavesList :: Atom -> [Atom]
leavesList atom = execWriter $ flip traverseLeaves atom $ \leaf ->
  tell [leaf] >> return leaf

copyAtom :: Atom -> Atom -> ImpM ()
copyAtom dest src = zipWithM_ copyLeaf (leavesList dest) (leavesList src)

copyLeaf :: Atom -> Atom -> ImpM ()
copyLeaf ~(Con (AGet dest)) src = case src of
  Con (AGet src') -> copy dest' (fromArrayAtom src')
  _ -> do src' <- fromScalarAtom src
          store dest' src'
  where dest' = fromArrayAtom dest

initializeAtomZero :: Atom -> ImpM ()
initializeAtomZero x = void $ flip traverseLeaves x $ \(~leaf@((Con (AGet dest)))) ->
  initializeZero (fromArrayAtom dest) >> return leaf

addToAtom :: Atom -> Atom -> ImpM ()
addToAtom dest src = zipWithM_ addToAtomLeaf (leavesList dest) (leavesList src)

addToAtomLeaf :: Atom -> Atom -> ImpM ()
addToAtomLeaf ~(Con (AGet dest)) src = case src of
  Con (AGet src') -> addToDestFromRef dest' (fromArrayAtom src')
  _ -> do
    src' <- fromScalarAtom src
    addToDestScalar dest' src'
  where dest' = fromArrayAtom dest

impProd :: [IExpr] -> ImpM IExpr
impProd []     = return $ IOne
impProd (x:xs) = foldrM impMul x xs

emitUnOp :: ScalarUnOp -> IExpr -> ImpM IExpr
emitUnOp op x = emitInstr $ IPrimOp $ ScalarUnOp op x

emitBinOp :: ScalarBinOp -> IExpr -> IExpr -> ImpM IExpr
emitBinOp op x y = emitInstr $ IPrimOp $ ScalarBinOp op x y

impAdd :: IExpr -> IExpr -> ImpM IExpr
impAdd IZero y = return y
impAdd x IZero = return x
impAdd (IIntVal x) (IIntVal y) = return $ IIntVal $ x + y
impAdd x y = emitBinOp IAdd x y

impMul :: IExpr -> IExpr -> ImpM IExpr
impMul IOne y = return y
impMul x IOne = return x
impMul (IIntVal x) (IIntVal y) = return $ IIntVal $ x * y
impMul x y = emitBinOp IMul x y

impDiv :: IExpr -> IExpr -> ImpM IExpr
impDiv x IOne = return x
impDiv x y = emitBinOp IDiv x y

impRem :: IExpr -> IExpr -> ImpM IExpr
impRem _ IOne = return IZero
impRem x y = emitBinOp Rem x y

impSub :: IExpr -> IExpr -> ImpM IExpr
impSub (IIntVal a) (IIntVal b)  = return $ IIntVal $ a - b
impSub a IZero = return a
impSub x y = emitBinOp ISub x y

impCmp :: CmpOp -> IExpr -> IExpr -> ImpM IExpr
impCmp GreaterEqual (IIntVal a) (IIntVal b) = return $ ILit $ BoolLit $ a >= b
impCmp op x y = emitBinOp (ICmp op) x y

-- Precondition: x and y don't have array types
impSelect :: IExpr -> IExpr -> IExpr -> ImpM IExpr
impSelect p x y = emitInstr $ IPrimOp $ Select p x y

-- === Imp embedding ===

copy :: IExpr -> IExpr -> ImpM ()
copy dest src = emitStatement (Nothing, Copy dest src)

load :: IExpr -> ImpM IExpr
load x = emitInstr $ Load x

store :: IExpr -> IExpr -> ImpM ()
store dest src = emitStatement (Nothing, Store dest src)

freshVar :: IVar -> ImpM IVar
freshVar v = do
  scope <- looks (fst . snd)
  let v' = rename v scope
  extend $ asSnd $ asFst (v' @> Nothing)
  return v'

emitLoop :: Direction -> IExpr -> (IExpr -> ImpM ()) -> ImpM ()
emitLoop d n body = do
  (i, loopBody) <- scopedBlock $ do
    i <- freshVar ("i":>IIntTy)
    body $ IVar i
    return i
  emitStatement (Nothing, Loop d i n loopBody)

scopedBlock :: ImpM a -> ImpM (a, ImpProg)
scopedBlock body = do
  (ans, (allocs, (_, prog))) <- scoped body
  let frees = ImpProg [(Nothing, Free v) | v <- allocs]
  return (ans, prog <> frees)

emitStatement :: ImpStatement -> ImpM ()
emitStatement statement = extend $ asSnd $ asSnd $ ImpProg [statement]

emitInstr :: ImpInstr -> ImpM IExpr
emitInstr instr = do
  case ignoreExcept (instrType instr) of
    Just ty -> do
      v <- freshVar ("v":>ty)
      emitStatement (Just v, instr)
      return $ IVar v
    Nothing -> error "Expected non-void result"

addToDestFromRef :: IExpr -> IExpr -> ImpM ()
addToDestFromRef dest src = case impExprType dest of
  IRefType (RealType, []) -> do
    cur  <- load dest
    src' <- load src
    updated <- emitInstr $ IPrimOp $ ScalarBinOp FAdd cur src'
    store dest updated
  IRefType (RealType, (n:_)) ->
    emitLoop Fwd n $ \i -> do
      dest' <- emitInstr $ IGet dest i
      src'  <- emitInstr $ IGet src  i
      addToDestFromRef dest' src'
  ty -> error $ "Addition not implemented for type: " ++ pprint ty

addToDestScalar :: IExpr -> IExpr -> ImpM ()
addToDestScalar dest src = do
  cur  <- load dest
  updated <- emitInstr $ IPrimOp $ ScalarBinOp FAdd cur src
  store dest updated

initializeZero :: IExpr -> ImpM ()
initializeZero ref = case impExprType ref of
  IRefType (RealType, []) -> store ref (ILit (RealLit 0.0))
  IRefType (RealType, (n:_)) ->
    emitLoop Fwd n $ \i -> emitInstr (IGet ref i) >>= initializeZero
  ty -> error $ "Zeros not implemented for type: " ++ pprint ty

-- === type checking imp programs ===

type ImpCheckM a = CatT (Env IType) (Either Err) a

instance Checkable ImpFunction where
   checkValid (ImpFunction vsOut vsIn prog) = do
     let env = foldMap varAsEnv $ vsOut ++ vsIn
     void $ runCatT (checkProg prog) env

checkProg :: ImpProg -> ImpCheckM ()
checkProg (ImpProg statements) = mapM_ checkStatement statements

checkStatement :: ImpStatement -> ImpCheckM ()
checkStatement (maybeBinder, instr) = do
  maybeTy <- instrTypeChecked instr
  case (maybeBinder, maybeTy) of
    (Nothing, Nothing) -> return ()
    (Nothing, Just _ ) -> throw CompilerErr $ "Result of non-void instruction must be assigned"
    (Just _ , Nothing) -> throw CompilerErr $ "Can't assign result of void instruction"
    (Just v@(_:>ty), Just ty') -> do
      env <- look
      when (v `isin` env) $ throw CompilerErr $ "shadows:" ++ pprint v
      checkValidType ty
      assertEq ty ty' "Type mismatch in instruction"
      extend $ v@>ty

instrTypeChecked :: ImpInstr -> ImpCheckM (Maybe IType)
instrTypeChecked instr = case instr of
  IPrimOp op -> liftM Just $ checkImpOp op
  Load ref -> do
    b <- (checkIExpr >=>  fromScalarRefType) ref
    return $ Just $ IValType b
  Store dest val -> do
    b <- (checkIExpr >=> fromScalarRefType) dest
    valTy <- checkIExpr val
    assertEq (IValType b) valTy "Type mismatch in store"
    return Nothing
  Copy dest source -> do
    destTy   <- (checkIExpr >=> fromRefType) dest
    sourceTy <- (checkIExpr >=> fromRefType) source
    assertEq sourceTy destTy "Type mismatch in copy"
    return Nothing
  Alloc ty -> return $ Just $ IRefType ty
  Free _   -> return Nothing  -- TODO: check matched alloc/free
  Loop _ i size block -> do
    checkInt size
    void $ scoped $ extend (i @> IIntTy) >> checkProg block
    return Nothing
  IGet e i -> do
    ~(IRefType (b, (_:shape))) <- checkIExpr e
    checkInt i
    return $ Just $ IRefType (b, shape)

checkValidType :: IType -> ImpCheckM ()
checkValidType (IValType _         ) = return ()
checkValidType (IRefType (_, shape)) = mapM_ checkInt shape

checkIExpr :: IExpr -> ImpCheckM IType
checkIExpr expr = case expr of
  ILit val -> return $ IValType (litType val)
  -- TODO: check shape matches vector length
  IVar v -> looks $ (! v)

checkInt :: IExpr -> ImpCheckM ()
checkInt expr = do
  ty <- checkIExpr expr
  assertEq (IValType IntType) ty $ "Not an int: " ++ pprint expr

checkImpOp :: IPrimOp -> ImpCheckM IType
checkImpOp op = do
  op' <- traverse checkIExpr op
  case op' of
    ScalarBinOp scalarOp x y -> do
      checkEq x (IValType x')
      checkEq y (IValType y')
      return $ IValType ty
      where (x', y', ty) = binOpType scalarOp
    ScalarUnOp scalarOp x -> do
      checkEq x (IValType x')
      return $ IValType ty
      where (x', ty) = unOpType scalarOp
    Select _ x y -> checkEq x y >> return x
    FFICall _ _ ty _   -> return $ IValType ty -- TODO: check
    _ -> error $ "Not allowed in Imp IR: " ++ pprint op
  where
    checkEq :: (Pretty a, Eq a) => a -> a -> ImpCheckM ()
    checkEq t t' = assertEq t t' (pprint op)

fromRefType :: MonadError Err m => IType -> m IArrayType
fromRefType (IRefType ty) = return ty
fromRefType ty = throw CompilerErr $ "Not a reference type: " ++ pprint ty

fromScalarRefType :: MonadError Err m => IType -> m BaseType
fromScalarRefType (IRefType (b, [])) = return b
fromScalarRefType ty = throw CompilerErr $ "Not a scalar reference type: " ++ pprint ty

impExprType :: IExpr -> IType
impExprType expr = case expr of
  ILit v    -> IValType (litType v)
  IVar (_:>ty) -> ty

instrType :: MonadError Err m => ImpInstr -> m (Maybe IType)
instrType instr = case instr of
  IPrimOp op      -> return $ Just $ impOpType op
  Load ref        -> liftM (Just . IValType) $ fromScalarRefType (impExprType ref)
  Store _ _       -> return Nothing
  Copy  _ _       -> return Nothing
  Alloc ty        -> return $ Just $ IRefType ty
  Free _          -> return Nothing
  Loop _ _ _ _    -> return Nothing
  IGet e _        -> case impExprType e of
    IRefType (b, (_:shape)) -> return $ Just $ IRefType (b, shape)
    ty -> error $ "Can't index into: " ++ pprint ty

impOpType :: IPrimOp -> IType
impOpType (ScalarBinOp op _ _) = IValType ty  where (_, _, ty) = binOpType op
impOpType (ScalarUnOp  op _  ) = IValType ty  where (_,    ty) = unOpType  op
impOpType (Select _ x _    )   = impExprType x
impOpType (FFICall _ _ ty _  ) = IValType ty
impOpType op = error $ "Not allowed in Imp IR: " ++ pprint op

pattern IIntTy :: IType
pattern IIntTy = IValType IntType

pattern IIntVal :: Int -> IExpr
pattern IIntVal x = ILit (IntLit x)

pattern IZero :: IExpr
pattern IZero = IIntVal 0

pattern IOne :: IExpr
pattern IOne = IIntVal 1
