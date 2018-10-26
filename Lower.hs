module Lower (VarName, VarEnv, initVarEnv, lowerExpr) where
import Prelude hiding (lookup)
import Util
import Control.Monad
import Control.Monad.Reader (ReaderT (..), runReaderT, local, ask)
import Syntax
import qualified Parser as P
import Parser (VarName, IdxVarName)

data LowerErr = UnboundVarErr VarName
              | UnboundIdxVarErr IdxVarName deriving (Show)

type Except a = Either LowerErr a
type VarEnv = [VarName]
type IdxVarEnv = [IdxVarName]
type Env = (VarEnv, IdxVarEnv)
type Lower a = ReaderT Env (Either LowerErr) a

lowerExpr :: P.Expr -> VarEnv -> Except Expr
lowerExpr expr env = runReaderT (lower expr) (env, [])

initVarEnv :: VarEnv
initVarEnv = ["iota", "reduce", "add", "sub", "mul", "div"]

lower :: P.Expr -> Lower Expr
lower expr = case expr of
  P.Lit c         -> return $ Lit c
  P.Var v         -> liftM  Var $ lookupEnv v
  P.Let v e body  -> liftM2 Let (lower e) $ local (updateEnv v) (lower body)
  P.Lam v body    -> liftM  Lam $ local (updateEnv v) (lower body)
  P.App fexpr arg -> liftM2 App (lower fexpr) (lower arg)
  P.For iv body   -> liftM  For $ local (updateIEnv iv) (lower body)
  P.Get e iv      -> liftM2 Get (lower e) (lookupIEnv iv)

updateEnv  v (env,ienv) = (v:env,ienv)
updateIEnv i (env,ienv) = (env,i:ienv)

lookupEnv :: VarName -> Lower Int
lookupEnv v = do
    (env,_) <- ask
    maybeReturn (lookup v env) $ UnboundVarErr v

lookupIEnv :: IdxVarName -> Lower Int
lookupIEnv iv = do
    (_,ienv) <- ask
    maybeReturn (lookup iv ienv) $ UnboundIdxVarErr iv

maybeReturn :: Maybe a -> LowerErr -> Lower a
maybeReturn (Just x) _ = return x
maybeReturn Nothing  e = ReaderT $ \_ -> Left e
