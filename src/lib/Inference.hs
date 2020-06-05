-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Inference (inferModule) where

import Control.Monad
import Control.Monad.Reader
import Control.Monad.Except hiding (Except)
import Data.Bitraversable
import Data.Foldable (fold, toList)
import qualified Data.Map.Strict as M
import Data.Text.Prettyprint.Doc

import Syntax
import Embed  hiding (sub)
import Env
import Record
import Type
import PPrint
import Cat

-- TODO: consider just carrying an `Atom` (since the type is easily recovered)
type InfEnv = Env (Atom, Type)
type UInferM = ReaderT InfEnv (ReaderT Effects (EmbedT (SolverT (Either Err))))

type SigmaType = Type  -- may     start with an implicit lambda
type RhoType   = Type  -- doesn't start with an implicit lambda
data RequiredTy a = Check a | Infer
data InferredTy a = Checked | Inferred a

inferModule :: TopEnv -> UModule -> Except (Module, TopInfEnv)
inferModule topEnv (UModule imports exports decls) = do
  let env = infEnvFromTopEnv topEnv
  let unboundVars = filter (\v -> not $ (v:>()) `isin` env) imports
  unless (null unboundVars) $
    throw UnboundVarErr $ pprintList unboundVars
  let shadowedVars = filter (\v -> (v:>()) `isin` env) exports
  unless (null shadowedVars) $
    throw RepeatedVarErr $ pprintList shadowedVars
  (env', decls') <- runUInferM (inferUDecls decls) env
  let combinedEnv = env <> env'
  let imports' = [v :> snd (env         ! (v:>())) | v <- imports]
  let exports' = [v :> snd (combinedEnv ! (v:>())) | v <- exports]
  let resultVals = [fst    (combinedEnv ! (v:>())) | v <- exports]
  let body = wrapDecls decls' $ TupVal resultVals
  return (Module Nothing imports' exports' body, (fmap snd env', mempty))

runUInferM :: (HasVars a, Pretty a) => UInferM a -> InfEnv -> Except (a, [Decl])
runUInferM m env =
  runSolverT $ runEmbedT (runReaderT (runReaderT m env) Pure) scope
  where scope = fmap (const Nothing) env

infEnvFromTopEnv :: TopEnv -> InfEnv
infEnvFromTopEnv (TopEnv (tyEnv, _) substEnv _) =
  fold [v' @> (substEnv ! v', ty) | (v, ty) <- envPairs tyEnv, let v' = v:>()]

checkSigma :: UExpr -> SigmaType -> UInferM Atom
checkSigma expr sTy = case sTy of
  Arrow ImplicitArrow piTy -> case expr of
    UPos _ (ULam ImplicitArrow pat body) ->
      checkULam ImplicitArrow pat body piTy
    _ -> do
      buildLam ImplicitArrow ("a":> absArgType piTy) $ \x ->
        case applyAbs piTy x of
          (Pure, ty) -> (Pure,) <$> checkSigma expr ty
          _ -> throw TypeErr "Implicit functions must not have effects"
  _ -> checkRho expr sTy

inferSigma :: UExpr -> UInferM (Atom, SigmaType)
inferSigma (UPos pos expr) = case expr of
  ULam ImplicitArrow pat body -> addSrcContext (Just pos) $
    inferULam Pure ImplicitArrow pat body
  _ ->
    inferRho (UPos pos expr)

checkRho :: UExpr -> RhoType -> UInferM Atom
checkRho expr ty = do
  (val, Checked) <- checkOrInferRho expr (Check ty)
  return val

inferRho :: UExpr -> UInferM (Atom, RhoType)
inferRho expr = do
  (val, Inferred ty) <- checkOrInferRho expr Infer
  return (val, ty)

-- This is necessary so that embed's `getType` doesn't get confused
-- TODO: figure out a better way. It's probably enough to just solve locally as
-- part of leak checking when we construct dependent lambdas.
emitZonked :: Expr -> UInferM Atom
emitZonked expr = zonk expr >>= emit

instantiateSigma :: (Atom, SigmaType) -> UInferM (Atom, RhoType)
instantiateSigma (f,  Arrow ImplicitArrow piTy) = do
  x <- freshInfVar $ absArgType piTy
  ans <- emitZonked $ App ImplicitArrow f x
  let (_, ansTy) = applyAbs piTy x
  instantiateSigma (ans, ansTy)
instantiateSigma (x, ty) = return (x, ty)

checkOrInferRho :: UExpr -> RequiredTy RhoType
                -> UInferM (Atom, InferredTy RhoType)
checkOrInferRho (UPos pos expr) reqTy =
 addSrcContext (Just pos) $ case expr of
  UVar v -> asks (! v) >>= instantiateSigma >>= matchRequirement
  ULam ImplicitArrow (RecLeaf b) body -> do
    argTy <- checkAnn $ varAnn b
    x <- freshInfVar argTy
    extendR (b@>(x, argTy)) $ checkOrInferRho body reqTy
  ULam ah pat body -> case reqTy of
    Check ty -> do
      (ahReq, piTy) <- fromArrowType ty
      checkArrowHead ahReq ah
      lam <- checkULam ahReq pat body piTy
      return (lam, Checked)
    Infer -> do
      (lam, ty) <- inferULam Pure ah pat body
      return (lam, Inferred ty)
  UFor dir pat body -> case reqTy of
    Check ty -> do
      (ah, Abs n (eff, a)) <- fromArrowType ty
      unless (ah == TabArrow && eff == Pure) $
        throw TypeErr $ "Not an table arrow type: " ++ pprint ty
      allowedEff <- lift ask
      lam <- checkULam PlainArrow pat body $ Abs n (allowedEff, a)
      result <- emitZonked $ Hof $ For dir lam
      return (result, Checked)
    Infer -> do
      allowedEff <- lift ask
      (lam, ty) <- inferULam allowedEff PlainArrow pat body
      (PlainArrow, Abs n (Pure, a)) <- fromArrowType ty
      result <- emitZonked $ Hof $ For dir lam
      return (result, Inferred $ Arrow TabArrow $ Abs n (Pure, a))
  UApp h f x -> do
    (fVal, fTy) <- inferRho f
    (hReq, piTy) <- fromArrowType fTy
    checkArrowHead hReq h
    xVal <- checkSigma x (absArgType piTy)
    let (appEff, appTy) = applyAbs piTy xVal
    checkEffectsAllowed appEff
    appVal <- emitZonked $ App hReq fVal xVal
    instantiateSigma (appVal, appTy) >>= matchRequirement
  UArrow h b@(v:>a) (eff, ty) -> do
    -- TODO: make sure there's no effect if it's an implicit or table arrow
    -- TODO: check leaks
    a'  <- checkUType a
    abs <- buildAbs (v:>a') $ \x -> extendR (b@>(x, a')) $
             (,) <$> checkUEff  eff <*> checkUType ty
    matchRequirement (Arrow h abs, TyKind)
  UDecl decl body -> do
    env <- inferUDecl decl
    extendR env $ checkOrInferRho body reqTy
  UPrimExpr prim -> do
    prim' <- traverse lookupName prim
    val <- case prim' of
      TCExpr  e -> return $ TC e
      ConExpr e -> return $ Con e
      OpExpr  e -> emitZonked $ Op e
      HofExpr e -> emitZonked $ Hof e
    matchRequirement (val, getType val)
    where lookupName  v = fst <$> asks (! (v:>()))
  where
    matchRequirement :: (Atom, Type) -> UInferM (Atom, InferredTy RhoType)
    matchRequirement (x, ty) = liftM (x,) $
      case reqTy of
        Infer -> return $ Inferred ty
        Check req -> do
          constrainEq req ty
          return Checked

inferUDecl :: UDecl -> UInferM InfEnv
inferUDecl (ULet (RecLeaf b@(_:>ann)) rhs) = case ann of
  Nothing -> do
    valAndTy <- inferSigma rhs
    return $ b@>valAndTy
  Just ty -> do
    ty' <- checkUType ty
    val <- checkSigma rhs ty'
    return $ b@>(val, ty')

inferUDecls :: [UDecl] -> UInferM InfEnv
inferUDecls decls = do
  initEnv <- ask
  liftM snd $ flip runCatT initEnv $ forM_ decls $ \decl -> do
    cur <- look
    new <- lift $ local (const cur) $ inferUDecl decl
    extend new

inferULam :: Effects -> ArrowHead -> UPat -> UExpr -> UInferM (Atom, Type)
inferULam eff ah (RecLeaf b@(v:>ann)) body = do
  argTy <- checkAnn ann
  buildLamAux ah (v:>argTy) $ \x@(Var v') -> do
    extendR (b @> (x, argTy)) $ do
      (resultVal, resultTy) <- withEffects eff $ inferSigma body
      let ty = Arrow ah $ makeAbs v' (eff, resultTy)
      return ((Pure, resultVal), ty)

checkULam :: ArrowHead -> UPat -> UExpr -> PiType -> UInferM Atom
checkULam ah (RecLeaf b@(v:>ann)) body piTy = do
  let argTy = absArgType piTy
  checkAnn ann >>= constrainEq argTy
  buildLam ah (v:>argTy) $ \x -> do
    let (eff, resultTy) = applyAbs piTy x
    extendR (b @> (x, argTy)) $ withEffects eff $ do
      result <- checkSigma body resultTy
      return (eff, result)

checkUEff :: UEffects -> UInferM Effects
checkUEff (UEffects effs tailVar) = case effs of
  [] -> case tailVar of
    Nothing -> return Pure
    Just v  -> checkRho v (TC EffectsKind)
  (effName, region):rest -> do
    region' <- checkRho region (TC RegionType)
    rest' <- checkUEff (UEffects rest tailVar)
    return $ Eff $ ExtendEff (effName, region') rest'

checkAnn :: Maybe UType -> UInferM Type
checkAnn ann = case ann of
  Just ty -> checkUType ty
  Nothing -> freshInfVar TyKind

checkUType :: UType -> UInferM Type
checkUType ty = do
  Just ty' <- reduceScoped $ withEffects Pure $ checkRho ty TyKind
  return ty'

freshInfVar :: Type -> UInferM Atom
freshInfVar ty = do
  (tv:>()) <- looks $ rename (rawName InferenceName "?" :> ()) . solverVars
  extend $ SolverEnv ((tv:>()) @> TyKind) mempty
  extendScope ((tv:>())@>Nothing)
  return $ Var $ tv:>ty

checkArrowHead :: ArrowHead -> ArrowHead -> UInferM ()
checkArrowHead ahReq ahOff = case (ahReq, ahOff) of
  (PlainArrow, PlainArrow) -> return ()
  (LinArrow,   PlainArrow) -> return ()
  (TabArrow,   TabArrow)   -> return ()
  _ -> throw TypeErr $   "Wrong arrow type:" ++
                       "\nExpected: " ++ pprint ahReq ++
                       "\nActual:   " ++ pprint ahOff

fromArrowType :: Type -> UInferM (ArrowHead, PiType)
fromArrowType (Arrow h piTy) = return (h, piTy)
fromArrowType ty = error $ "Not an arrow type: " ++ pprint ty

checkEffectsAllowed :: Effects -> UInferM ()
checkEffectsAllowed eff = do
  eff' <- zonk eff
  allowedEffects <- lift ask
  case forbiddenEffects allowedEffects eff' of
    Pure -> return ()
    extraEffs -> throw TypeErr $ "Unexpected effects: " ++ pprint extraEffs

withEffects :: Effects -> UInferM a -> UInferM a
withEffects effs m = modifyAllowedEffects (const effs) m

modifyAllowedEffects :: (Effects -> Effects) -> UInferM a -> UInferM a
modifyAllowedEffects f m = do
  env <- ask
  lift $ local f (runReaderT m env)

-- === constraint solver ===

data SolverEnv = SolverEnv { solverVars :: Env Kind
                           , solverSub  :: Env Type }
type SolverT m = CatT SolverEnv m

runSolverT :: (MonadError Err m, HasVars a, Pretty a)
           => CatT SolverEnv m a -> m a
runSolverT m = liftM fst $ flip runCatT mempty $ do
   ans <- m >>= zonk
   vs <- looks $ envNames . unsolved
   throwIf (not (null vs)) TypeErr $ "Ambiguous type variables: "
                                   ++ pprint vs ++ "\n\n" ++ pprint ans
   return ans

solveLocal :: (Pretty a, MonadCat SolverEnv m, MonadError Err m, HasVars a)
           => m a -> m a
solveLocal m = do
  (ans, env@(SolverEnv freshVars sub)) <- scoped (m >>= zonk)
  extend $ SolverEnv (unsolved env) (sub `envDiff` freshVars)
  return ans

checkLeaks :: (Pretty a, MonadCat SolverEnv m, MonadError Err m, HasVars a)
           => [Var] -> m a -> m a
checkLeaks tvs m = do
  (ans, env) <- scoped $ solveLocal m
  forM_ (solverSub env) $ \ty ->
    forM_ tvs $ \tv ->
      throwIf (tv `occursIn` ty) TypeErr $ "Leaked type variable: " ++ pprint tv
  extend env
  return ans

unsolved :: SolverEnv -> Env Kind
unsolved (SolverEnv vs sub) = vs `envDiff` sub

freshInferenceVar :: (MonadError Err m, MonadCat SolverEnv m) => Kind -> m Type
freshInferenceVar k = do
  tv <- looks $ rename (rawName InferenceName "?" :> k) . solverVars
  extend $ SolverEnv (tv @> k) mempty
  return (Var tv)

constrainEq :: (MonadCat SolverEnv m, MonadError Err m)
             => Type -> Type -> m ()
constrainEq t1 t2 = do
  t1' <- zonk t1
  t2' <- zonk t2
  let msg = "\nExpected: " ++ pprint t1'
         ++ "\n  Actual: " ++ pprint t2'
  addContext msg $ unify t1' t2'

zonk :: (HasVars a, MonadCat SolverEnv m) => a -> m a
zonk x = do
  s <- looks solverSub
  return $ tySubst s x

unify :: (MonadCat SolverEnv m, MonadError Err m)
       => Type -> Type -> m ()
unify t1 t2 = do
  t1' <- zonk t1
  t2' <- zonk t2
  vs <- looks solverVars
  case (t1', t2') of
    _ | t1' == t2' -> return ()
    (t, Var v) | v `isin` vs -> bindQ v t
    (Var v, t) | v `isin` vs -> bindQ v t
    (Arrow h piTy, Arrow h' piTy') | h == h' -> do
       unify (absArgType piTy) (absArgType piTy')
       let v = Var $ freshSkolemVar (piTy, piTy') (absArgType piTy)
       -- TODO: think very hard about the leak checks we need to add here
       let (eff , resultTy ) = applyAbs piTy  v
       let (eff', resultTy') = applyAbs piTy' v
       unify resultTy resultTy'
       unify eff eff'
    -- (Effect r t, Effect r' t') ->
    (TC con, TC con') | void con == void con' ->
      zipWithM_ unify (toList con) (toList con')
    _   -> throw TypeErr ""

rowMeet :: Env a -> Env b -> Env (a, b)
rowMeet (Env m) (Env m') = Env $ M.intersectionWith (,) m m'

bindQ :: (MonadCat SolverEnv m, MonadError Err m) => Var -> Type -> m ()
bindQ v t | v `occursIn` t = throw TypeErr (pprint (v, t))
          | hasSkolems t = throw TypeErr "Can't unify with skolem vars"
          | otherwise = extend $ mempty { solverSub = v @> t }

hasSkolems :: HasVars a => a -> Bool
hasSkolems x = not $ null [() | Name Skolem _ _ <- envNames $ freeVars x]

occursIn :: Var -> Type -> Bool
occursIn v t = v `isin` freeVars t

instance Semigroup SolverEnv where
  -- TODO: as an optimization, don't do the subst when sub2 is empty
  -- TODO: make concatenation more efficient by maintaining a reverse-lookup map
  SolverEnv scope1 sub1 <> SolverEnv scope2 sub2 =
    SolverEnv (scope1 <> scope2) (sub1' <> sub2)
    where sub1' = fmap (tySubst sub2) sub1

instance Monoid SolverEnv where
  mempty = SolverEnv mempty mempty
  mappend = (<>)

tySubst :: HasVars a => Env Type -> a -> a
tySubst env atom = subst (env, mempty) atom
