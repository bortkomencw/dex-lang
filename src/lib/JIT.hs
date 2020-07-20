-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module JIT (impToLLVM, mdImpToLLVM, impKernelToLLVM) where

import LLVM.AST (Operand, BasicBlock, Instruction, Named, Parameter)
import LLVM.Prelude (ShortByteString, Word32)
import qualified LLVM.AST as L
import qualified LLVM.AST.AddrSpace as L
import qualified LLVM.AST.DataLayout as L
import qualified LLVM.AST.Global as L
import qualified LLVM.AST.CallingConvention as L
import qualified LLVM.AST.Type as L
import qualified LLVM.AST.Typed as L
import qualified LLVM.AST.Float as L
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.FloatingPointPredicate as FPP
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.ParameterAttribute as L
import qualified LLVM.AST.FunctionAttribute as FA
import LLVM.IRBuilder.Instruction       (globalStringPtr)
import LLVM.IRBuilder.Internal.SnocList (SnocList (..))
import LLVM.IRBuilder.Module            (runModuleBuilder, ModuleBuilderState (..))

import Control.Monad
import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Identity
import Data.Maybe (fromJust)
import Data.ByteString.Short (toShort)
import Data.ByteString.Char8 (pack)
import Data.String
import Data.Foldable
import Data.Text.Prettyprint.Doc
import qualified Data.Set as S
import qualified Data.Map as M

import Array (vectorWidth)
import LLVMExec
import Syntax
import Env
import PPrint
import Cat
import Util

type OperandEnv = Env Operand
data CompileState = CompileState { curBlocks   :: [BasicBlock]
                                 , curInstrs   :: [Named Instruction]
                                 , scalarDecls :: [Named Instruction]
                                 , blockName   :: L.Name
                                 , usedNames   :: Env ()
                                 , progOutputs :: Env Operand  -- Maps Imp values to the output pointer operands
                                 , funSpecs    :: S.Set ExternFunSpec
                                 , globalDefs  :: [L.Definition]
                                 , allocas     :: S.Set L.Name
                                 }

type CompileT m    = ReaderT OperandEnv (StateT CompileState m)
type Compile       = CompileT Identity
data ExternFunSpec = ExternFunSpec L.Name L.Type [L.ParameterAttribute] [FA.FunctionAttribute] [L.Type]
                     deriving (Ord, Eq)

type Function = L.Global

-- === Imp to LLVM ===

impToLLVM :: ImpFunction -> LLVMFunction
impToLLVM (ImpFunction outVars inVars (ImpProg stmts)) =
  runIdentity $ compileFunction paramAttrs compileImpInstr outVars inVars stmts
  -- Alignment and dereferenceable attributes are guaranteed by malloc_dex
  where paramAttrs = [L.NoAlias, L.NoCapture, L.NonNull, L.Alignment 64, L.Dereferenceable 64]

compileImpInstr :: Bool -> ImpInstr -> Compile (Maybe Operand)
compileImpInstr isLocal instr = case instr of
  IPrimOp op       -> Just    <$> (traverse compileExpr op >>= compilePrimOp)
  Load ref         -> Just    <$> (load =<< compileExpr ref)
  Store dest val   -> Nothing <$  bindM2 store (compileExpr dest) (compileExpr val)
  IOffset x off _  -> Just    <$> bindM2 gep (compileExpr x) (compileExpr off)
  IWhile cond body -> Nothing <$  compileWhile cond body
  Alloc t numel  -> Just    <$> case numel of
    ILit (IntLit n) | isLocal && n <= 256 -> alloca n elemTy
    _ -> malloc elemTy =<< mul (sizeof elemTy) =<< compileExpr numel
    where elemTy = scalarTy $ scalarTableBaseType t
  Free v' -> do
    ~v@(L.LocalReference _ vn) <- lookupImpVar v'
    stackAllocated             <- gets allocas
    if vn `S.member` stackAllocated then return () else free v
    return Nothing
  Loop d i n body -> do
    n' <- compileExpr n
    compileLoop d i n' body
    return Nothing

compileLoop :: Direction -> IVar -> Operand -> ImpProg -> Compile ()
compileLoop d iVar n (ImpProg body) = do
  let loopName = "loop_" ++ (showName $ varName iVar)
  loopBlock <- freshName $ fromString $ loopName
  nextBlock <- freshName $ fromString $ "cont_" ++ loopName
  i <- alloca 1 longTy
  i0 <- case d of Fwd -> return $ litInt 0
                  Rev -> n `sub` litInt 1
  store i i0
  entryCond <- litInt 0 `ilt` n
  finishBlock (L.CondBr entryCond loopBlock nextBlock []) loopBlock
  iVal <- load i
  extendR (iVar @> iVal) $ compileProg compileImpInstr body
  iValNew <- case d of Fwd -> add iVal $ litInt 1
                       Rev -> sub iVal $ litInt 1
  store i iValNew
  loopCond <- case d of Fwd -> iValNew `ilt` n
                        Rev -> iValNew `ige` litInt 0
  finishBlock (L.CondBr loopCond loopBlock nextBlock []) nextBlock

compileIf :: Monad m => Operand -> CompileT m () -> CompileT m () -> CompileT m ()
compileIf cond tb fb = do
  tbName   <- freshName "if_true"
  fbName   <- freshName "if_false"
  contName <- freshName "if_cont"
  finishBlock (L.CondBr cond tbName fbName []) tbName
  tb
  finishBlock (L.Br contName []) fbName
  fb
  finishBlock (L.Br contName []) contName

compileWhile :: IExpr -> ImpProg -> Compile ()
compileWhile cond (ImpProg body) = do
  cond' <- compileExpr cond
  loopBlock <- freshName "whileLoop"
  nextBlock <- freshName "whileCont"
  entryCond <- load cond' >>= intToBool
  finishBlock (L.CondBr entryCond loopBlock nextBlock []) loopBlock
  compileProg compileImpInstr body
  loopCond <- load cond' >>= intToBool
  finishBlock (L.CondBr loopCond loopBlock nextBlock []) nextBlock

compilePrimOp :: Monad m => PrimOp Operand -> CompileT m Operand
compilePrimOp (ScalarBinOp op x y) = compileBinOp op x y
compilePrimOp (VectorBinOp op x y) = compileBinOp op x y
compilePrimOp (ScalarUnOp op x) = case op of
  BoolToInt       -> return x -- bools stored as ints
  UnsafeIntToBool -> return x -- bools stored as ints
  Exp             -> callRealIntrinsic "llvm.exp.f64"
  Exp2            -> callRealIntrinsic "llvm.exp2.f64"
  Log             -> callRealIntrinsic "llvm.log.f64"
  Log2            -> callRealIntrinsic "llvm.log2.f64"
  Log10           -> callRealIntrinsic "llvm.log10.f64"
  Sin             -> callRealIntrinsic "llvm.sin.f64"
  Cos             -> callRealIntrinsic "llvm.cos.f64"
  Tan             -> callRealIntrinsic "tan"  -- Technically not an intrinsic, but it works!
  Sqrt            -> callRealIntrinsic "llvm.sqrt.f64"
  Floor           -> do
    x' <- callRealIntrinsic "llvm.floor.f64"
    emitInstr longTy $ L.FPToSI x' longTy []
  Ceil            -> do
    x' <- callRealIntrinsic "llvm.ceil.f64"
    emitInstr longTy $ L.FPToSI x' longTy []
  Round           -> do
    x' <- callRealIntrinsic "llvm.round.f64"
    emitInstr longTy $ L.FPToSI x' longTy []
  IntToReal       -> emitInstr realTy $ L.SIToFP x realTy []
  -- LLVM has "fneg" but it doesn't seem to be exposed by llvm-hs-pure
  FNeg            -> emitInstr realTy $ L.FSub mathFlags (litReal 0.0) x []
  BNot            -> emitInstr boolTy $ L.Xor x (litInt 1) []
  where
    realIntrinsic name = ExternFunSpec name realTy [] [] [realTy]
    callRealIntrinsic name = emitExternCall (realIntrinsic name) [x]
compilePrimOp (Select p x y) = do
  p' <- intToBool p
  emitInstr (L.typeOf x) $ L.Select p' x y []
compilePrimOp (FFICall name ansTy xs) = do
  emitExternCall f xs
  where f = ExternFunSpec (L.Name (fromString name)) (scalarTy ansTy) [] [] (map L.typeOf xs)
compilePrimOp (VectorPack elems) = foldM fillElem undef $ zip elems [0..]
  where
    resTy = L.VectorType (fromIntegral vectorWidth) $ L.typeOf $ head elems
    fillElem v (e, i) = emitInstr resTy $ L.InsertElement v e (litInt i) []
    undef = L.ConstantOperand $ C.Undef resTy
compilePrimOp (VectorIndex v i) = emitInstr resTy $ L.ExtractElement v i []
  where (L.VectorType _ resTy) = L.typeOf v
compilePrimOp op = error $ "Can't JIT primop: " ++ pprint op

compileBinOp :: Monad m => BinOp -> Operand -> Operand -> CompileT m Operand
compileBinOp op x y = case op of
  IAdd   -> emitInstr longTy $ L.Add False False x y []
  ISub   -> emitInstr longTy $ L.Sub False False x y []
  IMul   -> emitInstr longTy $ L.Mul False False x y []
  IDiv   -> emitInstr longTy $ L.SDiv False x y []
  IRem   -> emitInstr longTy $ L.SRem x y []
  IPow   -> error "Not implemented"
  FPow   -> emitExternCall (realIntrinsic "llvm.pow.f64") [x, y]
  FAdd   -> emitInstr realTy $ L.FAdd mathFlags x y []
  FSub   -> emitInstr realTy $ L.FSub mathFlags x y []
  FMul   -> emitInstr realTy $ L.FMul mathFlags x y []
  FDiv   -> emitInstr realTy $ L.FDiv mathFlags x y []
  BAnd   -> emitInstr boolTy $ L.And x y []
  BOr    -> emitInstr boolTy $ L.Or  x y []
  ICmp c -> emitInstr boolTy (L.ICmp (intCmpOp   c) x y []) >>= (`zeroExtendTo` boolTy)
  FCmp c -> emitInstr boolTy (L.FCmp (floatCmpOp c) x y []) >>= (`zeroExtendTo` boolTy)
  where
    realIntrinsic name = ExternFunSpec name realTy [] [] [realTy, realTy]

    floatCmpOp :: CmpOp -> FPP.FloatingPointPredicate
    floatCmpOp cmpOp = case cmpOp of
      Less         -> FPP.OLT
      LessEqual    -> FPP.OLE
      Greater      -> FPP.OGT
      GreaterEqual -> FPP.OGE
      Equal        -> FPP.OEQ

    intCmpOp :: CmpOp -> IP.IntegerPredicate
    intCmpOp cmpOp = case cmpOp of
      Less         -> IP.SLT
      LessEqual    -> IP.SLE
      Greater      -> IP.SGT
      GreaterEqual -> IP.SGE
      Equal        -> IP.EQ

-- === MDImp to LLVM ===

type MDHostCompile   = Compile
data MDImpInstrCG    = EnsureHasContext -- code generation specific instructions
type MDImpInstrExt k = Either MDImpInstrCG (MDImpInstr k)

mdImpToLLVM :: MDImpFunction PTXKernel -> LLVMFunction
mdImpToLLVM (MDImpFunction outVars inVars (MDImpProg prog)) =
  runIdentity $ compileFunction [] compileMDImpInstr outVars inVars prog'
  where prog' = (Nothing, Left EnsureHasContext) : [(d, Right i) | (d, i) <- prog]

compileMDImpInstr :: Bool -> MDImpInstrExt PTXKernel -> MDHostCompile (Maybe Operand)
compileMDImpInstr isLocal instrExt = do
  case instrExt of
    Left ext -> case ext of
      EnsureHasContext -> ensureHasContext >> return Nothing
    Right instr -> case instr of
      MDLaunch size args (PTXKernel ptx) -> do
        m      <- cuModuleLoadData ptx
        kernel <- cuModuleGetFunction m "kernel"
        kernelArgs <- traverse lookupImpVar args
        let blockSizeX = 256
        sizeOp <- compileExpr size
        sizeOp' <- sizeOp `add` (litInt $ blockSizeX - 1)
        gridSizeX <- sizeOp' `div'` (litInt blockSizeX)
        cuLaunchKernel kernel
                      (gridSizeX        , litInt 1, litInt 1)
                      (litInt blockSizeX, litInt 1, litInt 1)
                      (sizeOp : kernelArgs)
        -- TODO: cuModuleUnload
        return Nothing
      MDAlloc  t s           -> Just <$> (cuMemAlloc elemTy =<< mul (sizeof elemTy) =<< compileExpr s)
        where elemTy = scalarTy $ scalarTableBaseType t
      MDFree   v             -> lookupImpVar v >>= cuMemFree >> return Nothing
      MDHostInstr impInstr   -> compileImpInstr isLocal impInstr

cuContextType :: L.Type
cuContextType = L.ptr L.VoidType

cuModuleType :: L.Type
cuModuleType = L.ptr L.VoidType

cuFunctionType :: L.Type
cuFunctionType = L.ptr L.VoidType

cuResultBitWidth :: Word32
cuResultBitWidth = 32  -- I guess? This is an enum, so the size might be compiler specific?

cuResultType :: L.Type
cuResultType = L.IntegerType cuResultBitWidth

cuDeviceType :: L.Type
cuDeviceType = L.IntegerType 32

cuStreamType :: L.Type
cuStreamType = L.ptr L.VoidType

-- CU_STREAM_LEGACY
cuDefaultStream :: Operand
cuDefaultStream = L.ConstantOperand $ C.IntToPtr (C.Int 64 1) cuStreamType

ensureHasContext :: MDHostCompile ()
ensureHasContext = do
  cuInit
  hasCtx <- threadHasCUDAContext
  compileIf hasCtx (return ()) $ do
    dev <- cuDeviceGet (L.ConstantOperand $ C.Int 32 0)
    ctx <- cuDevicePrimaryCtxRetain dev
    cuCtxPushCurrent ctx

threadHasCUDAContext :: MDHostCompile Operand
threadHasCUDAContext = do
  currentCtx <- cuCtxGetCurrent
  currentCtxInt <- emitInstr i64 $ L.PtrToInt currentCtx i64 []
  emitInstr i1 $ L.ICmp IP.UGT currentCtxInt (litInt 0) []

cuInit :: MDHostCompile ()
cuInit = checkCuResult "cuInit" =<< emitExternCall spec [L.ConstantOperand $ C.Int 32 0]
  where spec = ExternFunSpec "cuInit" cuResultType [] [] [i32]

cuCtxPushCurrent :: Operand -> MDHostCompile ()
cuCtxPushCurrent ctx = checkCuResult "cuCtxPushCurrent" =<< emitExternCall spec [ctx]
  where spec = ExternFunSpec "cuCtxPushCurrent" cuResultType [] [] [cuContextType]

cuCtxGetCurrent :: MDHostCompile Operand
cuCtxGetCurrent = do
  ctxPtr <- alloca 1 cuContextType
  checkCuResult "cuCtxGetCurrent" =<< emitExternCall spec [ctxPtr]
  load ctxPtr
  where spec = ExternFunSpec "cuCtxGetCurrent" cuResultType [] [] [L.ptr cuContextType]

cuDeviceGet :: Operand -> MDHostCompile Operand
cuDeviceGet ord = do
  devPtr <- alloca 1 cuDeviceType
  checkCuResult "cuDeviceGet" =<< emitExternCall spec [devPtr, ord]
  load devPtr
  where spec = ExternFunSpec "cuDeviceGet" cuResultType [] [] [L.ptr cuDeviceType, i32]

cuDevicePrimaryCtxRetain :: Operand -> MDHostCompile Operand
cuDevicePrimaryCtxRetain device = do
  ctxptr <- alloca 1 cuContextType
  checkCuResult "cuDevicePrimaryCtxRetain" =<< emitExternCall spec [ctxptr, device]
  load ctxptr
  where spec = ExternFunSpec "cuDevicePrimaryCtxRetain" cuResultType [] [] [L.ptr cuContextType, cuDeviceType]

cuModuleLoadData :: String -> MDHostCompile Operand
cuModuleLoadData ptx = do
  mptr <- alloca 1 cuModuleType
  ptxConst <- declareStringConst "ptxKernel" ptx
  ptxConstVoid <- castLPtr L.VoidType ptxConst
  checkCuResult "cuModuleLoadData" =<< emitExternCall spec [mptr, ptxConstVoid]
  load mptr
  where spec = ExternFunSpec "cuModuleLoadData" cuResultType [] [] [L.ptr cuModuleType, L.ptr L.VoidType]

cuModuleGetFunction :: Operand -> String -> MDHostCompile Operand
cuModuleGetFunction cuMod name = do
  fptr <- alloca 1 cuFunctionType
  nameConst <- declareStringConst "kernelName" name
  checkCuResult "cuModuleGetFunction" =<< emitExternCall spec [fptr, cuMod, nameConst]
  load fptr
  where spec = ExternFunSpec "cuModuleGetFunction" cuResultType [] [] [L.ptr cuFunctionType, cuModuleType, L.ptr i8]

cuLaunchKernel :: Operand -> (Operand, Operand, Operand) -> (Operand, Operand, Operand) -> [Operand] -> MDHostCompile ()
cuLaunchKernel fun grid block args = do
  kernelParams <- packArray args
  gridI32  <- makeDimArgs grid
  blockI32 <- makeDimArgs block
  checkCuResult "cuLaunchKernel" =<< emitExternCall spec
    (  [fun]
    ++ gridI32
    ++ blockI32
    ++ [L.ConstantOperand $ C.Int 32 0]       -- shared memory bytes per block
    ++ [cuDefaultStream]                      -- stream
    ++ [kernelParams]
    ++ [L.ConstantOperand $ C.Null $ L.ptr $ L.ptr L.VoidType] -- extra
    )
  where
    spec = ExternFunSpec "cuLaunchKernel" cuResultType [] []
             [ cuFunctionType
             , i32, i32, i32
             , i32, i32, i32
             , i32
             , cuStreamType
             , L.ptr $ L.ptr L.VoidType
             , L.ptr $ L.ptr L.VoidType ]

    makeDimArgs (x, y, z) = mapM (\v -> emitInstr i32 $ L.Trunc v i32 []) [x, y, z]

    packArray :: Monad m => [Operand] -> CompileT m Operand
    packArray elems = do
      arr <- alloca (length elems) (L.ptr $ L.VoidType)
      forM_ (zip [0..] elems) $ \(i, e) -> do
        eptr <- alloca 1 $ L.typeOf e
        store eptr e
        earr <- gep arr $ litInt i
        store earr =<< castLPtr L.VoidType eptr
      return arr

cuMemAlloc :: L.Type -> Operand -> MDHostCompile Operand
cuMemAlloc ty bytes = do
  ptrptr <- alloca 1 $ L.ptr $ L.VoidType
  checkCuResult "cuMemAlloc" =<< emitExternCall spec [ptrptr, bytes]
  castLPtr ty =<< load ptrptr
  where spec = ExternFunSpec "cuMemAlloc_v2" cuResultType [] [] [L.ptr $ L.ptr L.VoidType, i64]

cuMemFree :: Operand -> MDHostCompile ()
cuMemFree ptr = do
  voidPtr <- castLPtr L.VoidType ptr
  checkCuResult "cuMemFree" =<< emitExternCall spec [voidPtr]
  where spec = ExternFunSpec "cuMemFree_v2" cuResultType [] [] [L.ptr L.VoidType]

declareStringConst :: Monad m => Name -> String -> CompileT m Operand
declareStringConst nameHint str = do
  name <- freshName nameHint
  let (ptr, [def]) = runModuleBuilder (ModuleBuilderState (SnocList []) mempty) $ globalStringPtr str name
  modify $ (\s -> s { globalDefs = def : (globalDefs s) })
  return $ L.ConstantOperand ptr

checkCuResult :: String -> Operand -> MDHostCompile ()
checkCuResult msg result = do
  isOk <- emitInstr i1 $ L.ICmp IP.EQ result okResult []
  compileIf isOk (return ()) $ do
    msgConst <- declareStringConst "checkFailMsg" msg
    _ <- emitExternCall putsSpec [msgConst]
    emitVoidExternCall abortSpec []
  where
    okResult = L.ConstantOperand $ C.Int cuResultBitWidth 0
    abortSpec = ExternFunSpec "abort" L.VoidType [] [] []
    putsSpec = ExternFunSpec "puts" i32 [] [] [L.ptr i8]

-- === GPU Kernel compilation ===

impKernelToLLVM :: ImpKernel -> LLVMKernel
impKernelToLLVM (ImpKernel args lvar (ImpProg prog)) = runCompile mempty $ do
  (argParams, argOperands) <- unzip <$> mapM (freshParamOpPair ptrParamAttrs) argTypes
  (sizeParam, sizeOperand) <- freshParamOpPair [] longTy
  tidx <- threadIdxX
  bidx <- blockIdxX
  bsz  <- blockDimX
  lidx <- mul bidx bsz >>= (add tidx)
  outOfBounds <- emitInstr i1 $ L.ICmp IP.UGE lidx sizeOperand []
  compileIf outOfBounds (return ()) $ do
    let paramEnv = foldMap (uncurry (@>)) $ zip args argOperands
    -- TODO: Use a restricted form of compileProg that e.g. never emits FFI calls!
    extendR (paramEnv <> lvar @> lidx) $ compileProg compileImpInstr prog
  kernel <- makeFunction "kernel" (sizeParam : argParams)
  LLVMKernel <$> makeModuleEx ptxDataLayout targetTriple [L.GlobalDefinition kernel, kernelMeta, nvvmAnnotations]
  where
    ptrParamAttrs = [L.NoAlias, L.NoCapture, L.NonNull, L.Alignment 256]
    argTypes = fmap ((fromIType $ L.AddrSpace 1). varAnn) args
    kernelMetaId = L.MetadataNodeID 0
    kernelMeta = L.MetadataNodeDefinition kernelMetaId $ L.MDTuple
      [ Just $ L.MDValue $ L.ConstantOperand $ C.GlobalReference (funTy L.VoidType (longTy : argTypes)) "kernel"
      , Just $ L.MDString "kernel"
      , Just $ L.MDValue $ L.ConstantOperand $ C.Int 32 1
      ]
    nvvmAnnotations = L.NamedMetadataDefinition "nvvm.annotations" [kernelMetaId]
    targetTriple = "nvptx64-nvidia-cuda"
    ptxDataLayout = (L.defaultDataLayout L.LittleEndian)
      { L.endianness     = L.LittleEndian
      , L.pointerLayouts = M.fromList [(L.AddrSpace 0, (64, L.AlignmentInfo 64 64))]
      , L.typeLayouts    = M.fromList $
          [ ((L.IntegerAlign, 1), L.AlignmentInfo 8 8) ] ++
          [ ((L.IntegerAlign, w), L.AlignmentInfo w w) | w <- [8, 16, 32, 64] ] ++
          [ ((L.FloatAlign,   w), L.AlignmentInfo w w) | w <- [32, 64] ] ++
          [ ((L.VectorAlign,  w), L.AlignmentInfo w w) | w <- [16, 32, 64, 128] ]
      , L.nativeSizes    = Just $ S.fromList [16, 32, 64]
      }

threadIdxX :: Compile Operand
threadIdxX = emitExternCall spec [] >>= (`zeroExtendTo` longTy)
  where spec = ptxSpecialReg "llvm.nvvm.read.ptx.sreg.tid.x"

blockIdxX :: Compile Operand
blockIdxX = emitExternCall spec [] >>= (`zeroExtendTo` longTy)
  where spec = ptxSpecialReg "llvm.nvvm.read.ptx.sreg.ctaid.x"

blockDimX :: Compile Operand
blockDimX = emitExternCall spec [] >>= (`zeroExtendTo` longTy)
  where spec = ptxSpecialReg "llvm.nvvm.read.ptx.sreg.ntid.x"

ptxSpecialReg :: L.Name -> ExternFunSpec
ptxSpecialReg name = ExternFunSpec name i32 [] [FA.ReadNone, FA.NoUnwind] []

-- === Helpers for Imp and MDImp programs ===

compileFunction :: Monad m
                => [L.ParameterAttribute]
                -> (Bool -> instr -> CompileT m (Maybe Operand))
                -> [ScalarTableVar] -> [ScalarTableVar] -> [Statement instr] -> m LLVMFunction
compileFunction attrs compileInstr outVars inVars stmts = runCompileT mempty $ do
  -- Set up the argument list. Note that all outputs are pointers to pointers.
  let inVarTypes  = map (        fromArrType . varAnn) inVars
  let outVarTypes = map (L.ptr . fromArrType . varAnn) outVars
  (inParams, inOperands)   <- unzip <$> mapM (freshParamOpPair attrs) inVarTypes
  (outParams, outOperands) <- unzip <$> mapM (freshParamOpPair attrs) outVarTypes

  -- Emit the program
  let paramEnv = newEnv inVars inOperands
  modify (\s -> s { progOutputs = zipEnv outVars outOperands })
  extendR paramEnv $ compileProg compileInstr stmts

  let params = outParams ++ inParams
  let paramTypes = fmap L.typeOf params
  mainFun <- makeFunction "mainFun" params

  let mainFunOp = callableOperand (funTy L.VoidType paramTypes) "mainFun"
  let entryFun = makeEntryPoint "entryFun" paramTypes mainFunOp
  LLVMFunction numOutputs <$> makeModule [L.GlobalDefinition mainFun,
                                          L.GlobalDefinition entryFun]
  where
    dropArray t = case t of ArrayTy t' -> t'; _ -> t
    fromArrType = (fromIType $ L.AddrSpace 0) . IRefType . dropArray
    numOutputs = length outVars

compileProg :: Monad m => (Bool -> instr -> CompileT m (Maybe Operand)) -> [Statement instr] -> CompileT m ()
compileProg _ [] = return ()
compileProg compileInstr ((maybeName, instr):prog) = do
  outputs <- gets progOutputs
  let isOutput = case maybeName of
                    Just name -> name `isin` outputs
                    Nothing   -> False
  maybeAns <- compileInstr (not isOutput) instr
  let env = case (maybeName, maybeAns) of
              (Nothing, Nothing) -> mempty
              (Just v, Just ans) -> v @> ans
              _ -> error "Void mismatch"
  if isOutput
    then store (outputs ! (fromJust maybeName)) (fromJust maybeAns)
    else return ()
  extendR env $ compileProg compileInstr prog

compileExpr :: Monad m => IExpr -> CompileT m Operand
compileExpr expr = case expr of
  ILit v   -> return (litVal v)
  IVar v   -> lookupImpVar v

-- === LLVM embedding ===

litVal :: LitVal -> Operand
litVal lit = case lit of
  IntLit  x -> litInt x
  RealLit x -> litReal x
  BoolLit True  -> litInt 1
  BoolLit False -> litInt 0
  VecLit l  -> L.ConstantOperand $ foldl fillElem undef $ zip consts [0..length l - 1]
    where
      consts = fmap (operandToConst . litVal) l
      undef = C.Undef $ L.VectorType (fromIntegral $ length l) $ L.typeOf $ head consts
      fillElem v (c, i) = C.InsertElement v c (C.Int 64 (fromIntegral i))
      operandToConst ~(L.ConstantOperand c) = c
  StrLit _ -> error "Not implemented"

litInt :: Int -> Operand
litInt x = L.ConstantOperand $ C.Int 64 (fromIntegral x)

litReal :: Double -> Operand
litReal x = L.ConstantOperand $ C.Float $ L.Double x

store :: Monad m => Operand -> Operand -> CompileT m ()
store ptr x =  addInstr $ L.Do $ L.Store False ptr x Nothing 0 []

load :: Monad m => Operand -> CompileT m Operand
load ptr = emitInstr ty $ L.Load False ptr Nothing 0 []
  where (L.PointerType ty _) = L.typeOf ptr

ilt :: Monad m => Operand -> Operand -> CompileT m Operand
ilt x y = emitInstr i1 $ L.ICmp IP.SLT x y []

ige :: Monad m => Operand -> Operand -> CompileT m Operand
ige x y = emitInstr i1 $ L.ICmp IP.SGE x y []

add :: Monad m => Operand -> Operand -> CompileT m Operand
add x y = emitInstr longTy $ L.Add False False x y []

sub :: Monad m => Operand -> Operand -> CompileT m Operand
sub x y = emitInstr longTy $ L.Sub False False x y []

mul :: Monad m => Operand -> Operand -> CompileT m Operand
mul x y = emitInstr longTy $ L.Mul False False x y []

div' :: Monad m => Operand -> Operand -> CompileT m Operand
div' x y = emitInstr longTy $ L.SDiv False x y []

gep :: Monad m => Operand -> Operand -> CompileT m Operand
gep ptr i = emitInstr (L.typeOf ptr) $ L.GetElementPtr False ptr [i] []

sizeof :: L.Type -> Operand
sizeof t = (L.ConstantOperand $ C.ZExt (C.sizeof t) longTy)

alloca :: Monad m => Int -> L.Type -> CompileT m Operand
alloca elems ty = do
  v <- freshName "v"
  modify $ setScalarDecls ((v L.:= instr):)
  modify $ setAllocas (S.insert v)
  return $ L.LocalReference (L.ptr ty) v
  where instr = L.Alloca ty (Just $ litInt elems) 0 []

malloc :: Monad m => L.Type -> Operand -> CompileT m Operand
malloc ty bytes = do
  bytes64 <- asIntWidth bytes i64
  voidPtr <- emitExternCall mallocFun [bytes64]
  castLPtr ty voidPtr

free :: Monad m => Operand -> CompileT m ()
free ptr = do
  ptr' <- castLPtr i8 ptr
  emitVoidExternCall freeFun [ptr']

castLPtr :: Monad m => L.Type -> Operand -> CompileT m Operand
castLPtr ty ptr = emitInstr (L.ptr ty) $ L.BitCast ptr (L.ptr ty) []

zeroExtendTo :: Monad m => Operand -> L.Type -> CompileT m Operand
zeroExtendTo x t = emitInstr t $ L.ZExt x t []

intToBool :: Monad m => Operand -> CompileT m Operand
intToBool x = emitInstr (L.IntegerType 1) $ L.Trunc x (L.IntegerType 1) []

callInstr :: L.CallableOperand -> [L.Operand] -> L.Instruction
callInstr fun xs = L.Call Nothing L.C [] fun xs' [] []
 where xs' = [(x ,[]) | x <- xs]

externCall :: ExternFunSpec -> [L.Operand] -> L.Instruction
externCall (ExternFunSpec fname retTy _ _ argTys) xs = callInstr fun xs
  where fun = callableOperand (funTy retTy argTys) fname

emitExternCall :: Monad m => ExternFunSpec -> [L.Operand] -> CompileT m Operand
emitExternCall f@(ExternFunSpec _ retTy _ _ _) xs = do
  modify $ setFunSpecs (S.insert f)
  emitInstr retTy $ externCall f xs

emitVoidExternCall :: Monad m => ExternFunSpec -> [L.Operand] -> CompileT m ()
emitVoidExternCall f xs = do
  modify $ setFunSpecs (S.insert f)
  addInstr $ L.Do $ externCall f xs

scalarTy :: BaseType -> L.Type
scalarTy b = case b of
  Scalar sb -> case sb of
    IntType  -> longTy
    RealType -> realTy
    BoolType -> boolTy -- Still storing in 64-bit arrays TODO: use 8 bits (or 1)
    StrType  -> error "Not implemented"
  Vector sb -> L.VectorType (fromIntegral vectorWidth) $ scalarTy $ Scalar sb

fromIType :: L.AddrSpace -> IType -> L.Type
fromIType addrSpace it = case it of
  IValType b -> scalarTy b
  IRefType t -> L.PointerType (scalarTy $ scalarTableBaseType t) addrSpace

callableOperand :: L.Type -> L.Name -> L.CallableOperand
callableOperand ty name = Right $ L.ConstantOperand $ C.GlobalReference ty name

showName :: Name -> String
showName (Name GenName tag counter) = asStr $ pretty tag <> "." <> pretty counter
showName _ = error $ "All names in JIT should be from the GenName namespace"

asIntWidth :: Monad m => Operand -> L.Type -> CompileT m Operand
asIntWidth op ~expTy@(L.IntegerType expWidth) = case compare expWidth opWidth of
  LT -> emitInstr expTy $ L.Trunc op expTy []
  EQ -> return op
  GT -> emitInstr expTy $ L.ZExt  op expTy []
  where ~(L.IntegerType opWidth) = L.typeOf op

freshParamOpPair :: Monad m => [L.ParameterAttribute] -> L.Type -> CompileT m (Parameter, Operand)
freshParamOpPair ptrAttrs ty = do
  v <- freshName "arg"
  let attrs = case ty of
                L.PointerType _ _ -> ptrAttrs
                _ -> []
  return (L.Parameter ty v attrs, L.LocalReference ty v)

externDecl :: ExternFunSpec -> L.Definition
externDecl (ExternFunSpec fname retTy retAttrs funAttrs argTys) =
  L.GlobalDefinition $ L.functionDefaults {
    L.name               = fname
  , L.parameters         = ([L.Parameter t (argName i) []
                            | (i, t) <- zip [0::Int ..] argTys], False)
  , L.returnType         = retTy
  , L.returnAttributes   = retAttrs
  , L.functionAttributes = fmap Right funAttrs
  }
  where argName i = L.Name $ "arg" <> fromString (show i)

-- === Compile monad utilities ===

runCompileT :: Monad m => OperandEnv -> CompileT m a -> m a
runCompileT env m = evalStateT (runReaderT m env ) initState
  where initState = CompileState [] [] [] "start_block" mempty mempty mempty mempty mempty

runCompile :: OperandEnv -> Compile a -> a
runCompile env m = runIdentity $ runCompileT env m

lookupImpVar :: Monad m => IVar -> CompileT m Operand
lookupImpVar v = asks (! v)

finishBlock :: Monad m => L.Terminator -> L.Name -> CompileT m ()
finishBlock term newName = do
  oldName <- gets blockName
  instrs  <- gets curInstrs
  let newBlock = L.BasicBlock oldName (reverse instrs) (L.Do term)
  modify $ setCurBlocks (newBlock:)
         . setCurInstrs (const [])
         . setBlockName (const newName)

freshName :: Monad m => Name -> CompileT m L.Name
freshName v = do
  used <- gets usedNames
  let v'@(name:>_) = rename (v:>()) used
  modify $ \s -> s { usedNames = used <> v'@>() }
  return $ nameToLName name
  where
    nameToLName :: Name -> L.Name
    nameToLName name = L.Name $ toShort $ pack $ showName name

-- TODO: consider getting type from instruction rather than passing it explicitly
emitInstr :: Monad m => L.Type -> Instruction -> CompileT m Operand
emitInstr ty instr = do
  v <- freshName "v"
  addInstr $ v L.:= instr
  return $ L.LocalReference ty v

addInstr :: Monad m => Named Instruction -> CompileT m ()
addInstr instr = modify $ setCurInstrs (instr:)

setScalarDecls :: ([Named Instruction] -> [Named Instruction]) -> CompileState -> CompileState
setScalarDecls update s = s { scalarDecls = update (scalarDecls s) }

setAllocas :: (S.Set L.Name -> S.Set L.Name) -> CompileState -> CompileState
setAllocas update s = s { allocas = update (allocas s) }

setCurInstrs :: ([Named Instruction] -> [Named Instruction]) -> CompileState -> CompileState
setCurInstrs update s = s { curInstrs = update (curInstrs s) }

setCurBlocks :: ([BasicBlock] -> [BasicBlock]) -> CompileState -> CompileState
setCurBlocks update s = s { curBlocks   = update (curBlocks s) }

setBlockName :: (L.Name -> L.Name) -> CompileState -> CompileState
setBlockName update s = s { blockName = update (blockName s) }

setFunSpecs :: (S.Set ExternFunSpec -> S.Set ExternFunSpec) -> CompileState -> CompileState
setFunSpecs update s = s { funSpecs = update (funSpecs s) }

-- === Constants ===

-- FP contractions should only lead to fewer rounding points, so we allow those
mathFlags :: L.FastMathFlags
mathFlags = L.noFastMathFlags { L.allowContract = True }

mallocFun :: ExternFunSpec
mallocFun = ExternFunSpec "malloc_dex" (L.ptr i8) [L.NoAlias] [] [i64]

freeFun :: ExternFunSpec
freeFun = ExternFunSpec "free_dex" L.VoidType [] [] [L.ptr i8]

longTy :: L.Type
longTy = i64

realTy :: L.Type
realTy = fp64

boolTy :: L.Type
boolTy = i64

fp64 :: L.Type
fp64 = L.FloatingPointType L.DoubleFP

i64 :: L.Type
i64 = L.IntegerType 64

i32 :: L.Type
i32 = L.IntegerType 32

i8 :: L.Type
i8 = L.IntegerType 8

i1 :: L.Type
i1 = L.IntegerType 1

funTy :: L.Type -> [L.Type] -> L.Type
funTy retTy argTys = L.ptr $ L.FunctionType retTy argTys False

-- === Module building ===

makeFunction :: Monad m => L.Name -> [Parameter] -> CompileT m Function
makeFunction name params = do
  finishBlock (L.Ret Nothing []) "<ignored>"
  decls <- gets scalarDecls
  ~((L.BasicBlock bbname instrs term):blocksTail) <- gets (reverse . curBlocks)
  let blocks = (L.BasicBlock bbname (decls ++ instrs) term):blocksTail
  return $ L.functionDefaults
    { L.name        = name
    , L.parameters  = (params, False)
    , L.returnType  = L.VoidType
    , L.basicBlocks = blocks }

makeModule :: Monad m => [L.Definition] -> CompileT m L.Module
makeModule defs = do
  specs     <- gets funSpecs
  extraDefs <- gets globalDefs
  return $ L.defaultModule
      { L.moduleName = "dexModule"
      , L.moduleDefinitions = extraDefs ++ defs ++ fmap externDecl (toList specs) }

makeModuleEx :: Monad m => L.DataLayout -> ShortByteString -> [L.Definition] -> CompileT m L.Module
makeModuleEx dataLayout triple defs = do
  specs <- gets funSpecs
  return $ L.defaultModule
      { L.moduleName = "dexModule"
      , L.moduleDefinitions = defs ++ fmap externDecl (toList specs)
      , L.moduleDataLayout = Just dataLayout
      , L.moduleTargetTriple = Just triple }

makeEntryPoint :: L.Name -> [L.Type] -> L.CallableOperand -> Function
makeEntryPoint wrapperName argTypes f = runCompile mempty $ do
  (argParam, argOperand) <- freshParamOpPair [] (L.ptr $ L.ptr i8)
  args <- forM (zip [0..] argTypes) $ \(i, ty) -> do
    curPtr <- gep argOperand $ litInt i
    arg <- case ty of
      L.PointerType (L.PointerType _ _) _ -> return curPtr
      L.PointerType _ _                   -> load curPtr
      _                                   -> error "Expected a pointer type"
    emitInstr ty $ L.BitCast arg ty []
  addInstr $ L.Do $ callInstr f args
  makeFunction wrapperName [argParam]

instance Pretty L.Operand where
  pretty x = pretty (show x)

instance PrettyPrec L.Operand where
  prettyPrec = atPrec AppPrec . pretty 

instance Pretty L.Type where
  pretty x = pretty (show x)
