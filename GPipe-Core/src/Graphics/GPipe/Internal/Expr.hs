{-# LANGUAGE GADTs #-}
{-# LANGUAGE EmptyDataDecls, NoMonomorphismRestriction,
  TypeFamilies, ScopedTypeVariables, FlexibleInstances, RankNTypes,
  MultiParamTypeClasses, FlexibleContexts, OverloadedStrings #-}

module Graphics.GPipe.Internal.Expr where

import Prelude hiding ((.), id)
import Data.Word
import Control.Category
import Control.Monad (void, when)
import Control.Monad.Trans.Writer
import Control.Monad.Trans.State
import Control.Monad.Trans.Reader
import Data.Monoid (mconcat, mappend)
import qualified Control.Monad.Trans.Class as T (lift)
import Data.SNMap
import qualified Data.IntMap as Map
import Data.Boolean
import Data.List (intercalate)
import Control.Applicative ((<$>))

type NextTempVar = Int
type NextGlobal = Int

data SType = STypeFloat | STypeInt | STypeBool | STypeUInt | STypeDyn String | STypeVec Int | STypeIVec Int | STypeUVec Int 

stypeName :: SType -> String
stypeName STypeFloat = "float"
stypeName STypeInt = "int"
stypeName STypeBool = "bool"
stypeName STypeUInt = "uint"
stypeName (STypeDyn s) = s
stypeName (STypeVec n) = "vec" ++ show n
stypeName (STypeIVec n) = "ivec" ++ show n
stypeName (STypeUVec n) = "uvec" ++ show n

stypeSize :: SType -> Int
stypeSize (STypeVec n) = n * 4
stypeSize (STypeIVec n) = n * 4
stypeSize (STypeUVec n) = n * 4
stypeSize _ = 4

type ExprM = SNMapReaderT [String] (StateT ExprState (WriterT String (StateT NextTempVar IO))) -- IO for stable names
data ExprState = ExprState { 
                shaderUsedUniformBlocks :: Map.IntMap (GlobDeclM ()), 
                shaderUsedSamplers :: Map.IntMap (GlobDeclM ()),
                shaderUsedInput :: Map.IntMap (GlobDeclM (), (ExprM (), GlobDeclM ())) -- For vertex shaders, the shaderM is always undefined and the int is the parameter name, for later shader stages it uses some name local to the transition instead    
                 }
                
runExprM :: GlobDeclM () -> ExprM () -> IO (String, [Int], [Int], [Int], GlobDeclM (), ExprM ())
runExprM d m = do
               (st, body) <- evalStateT (runWriterT (execStateT (runSNMapReaderT (m :: ExprM ())) (ExprState Map.empty Map.empty Map.empty))) 0
               let (unis, uniDecls) = unzip $ Map.toAscList (shaderUsedUniformBlocks st)
                   (samps, sampDecls) = unzip $ Map.toAscList (shaderUsedSamplers st)
                   (inps, inpDescs) = unzip $ Map.toAscList (shaderUsedInput st)
                   (inpDecls, prevDesc) = unzip inpDescs
                   (prevSs, prevDecls) = unzip prevDesc
                   decls = do d
                              sequence_ uniDecls 
                              sequence_ sampDecls
                              sequence_ inpDecls
                   source = mconcat [
                                execWriter decls,
                                "main() {\n",
                                body,
                                "}"]   
               return (source, unis, samps, inps, sequence_ prevDecls, sequence_ prevSs)

type GlobDeclM = Writer String

newtype S c a = S { unS :: ExprM String } 

scalarS :: SType -> ExprM RValue -> S c a
scalarS typ = S . tellAssignment typ 

vec2S :: SType -> ExprM RValue -> (S c a, S c a)
vec2S typ s = let (x,y,_z,_w) = vec4S typ s
              in (x,y)
vec3S :: SType -> ExprM RValue -> (S c a, S c a, S c a)
vec3S typ s = let (x,y,z,_w) = vec4S typ s
              in (x,y,z)
vec4S :: SType -> ExprM RValue -> (S c a, S c a, S c a, S c a)
vec4S typ s = let m = tellAssignment typ s
                  f p = S $ fmap (++ p) m
              in (f ".x", f ".y", f".z", f ".w")

scalarS' :: RValue -> S c a
scalarS' = S . return
 
vec2S' :: RValue -> (S c a, S c a)
vec2S' s = let (x,y,_z,_w) = vec4S' s
           in (x,y)
vec3S' :: RValue -> (S c a, S c a, S c a)
vec3S' s = let (x,y,z,_w) = vec4S' s
           in (x,y,z)
vec4S' :: RValue -> (S c a, S c a, S c a, S c a)
vec4S' s = let f p = S $ return (s ++ p)
           in (f ".x", f ".y", f".z", f ".w")

vec2S'' :: S c a -> (S c a, S c a)
vec2S'' s = let (x,y,_z,_w) = vec4S'' s
            in (x,y)
vec3S'' :: S c a -> (S c a, S c a, S c a)
vec3S'' s = let (x,y,z,_w) = vec4S'' s
            in (x,y,z)
vec4S'' :: S c a -> (S c a, S c a, S c a, S c a)
vec4S'' s = let f p = S $ fmap (++ p) (unS s)
            in (f ".x", f ".y", f".z", f ".w")

           
data V
--data P
data F

type VFloat = S V Float
type VInt = S V Int
type VWord = S V Word
type VBool = S V Bool

type FFloat = S F Float
type FInt = S F Int
type FWord = S F Word
type FBool = S F Bool

--getNextGlobal :: Monad m => StateT Int m Int
--getNextGlobal = do
--    s <- get
--    put $ s + 1 
--    return s

-- TODO: Add func to generate shader decl header

useVInput :: SType -> Int -> ExprM String
useVInput stype i = 
             do s <- T.lift get
                T.lift $ put $ s { shaderUsedInput = Map.insert i (gDeclInput, undefined) $ shaderUsedInput s }                
                return $ "in" ++ show i
    where
        gDeclInput = do tellGlobal "in "
                        tellGlobal $ stypeName stype          
                        tellGlobal " in"
                        tellGlobalLn $ show i

useFInput :: String -> String -> SType -> Int -> ExprM String -> ExprM String
useFInput qual prefix stype i v =
             do s <- T.lift get
                T.lift $ put $ s { shaderUsedInput = Map.insert i (gDecl (qual ++ " in "), (assignOutput, gDecl (qual ++ " out "))) $ shaderUsedInput s }                
                return $ prefix ++ show i
    where
        assignOutput = do val <- v
                          let name = prefix ++ show i
                          tellAssignment' name val
                    
        gDecl s =    do tellGlobal s
                        tellGlobal $ stypeName stype          
                        tellGlobal $ ' ':prefix
                        tellGlobalLn $ show i

   
useUniform :: GlobDeclM () -> Int -> Int -> ExprM String
useUniform decls blockI offset = 
             do T.lift $ modify $ \ s -> s { shaderUsedUniformBlocks = Map.insert blockI gDeclUniformBlock $ shaderUsedUniformBlocks s } 
                return $ 'u':show blockI ++ '.':'u': show offset -- "u8.u4"
    where
        gDeclUniformBlock =
            do  let blockStr = show blockI
                tellGlobal "uniform uBlock"
                tellGlobal blockStr
                tellGlobal " {\n"
                decls
                tellGlobal "} u"
                tellGlobalLn blockStr

useSampler :: String -> Int -> ExprM String
useSampler str name = 
             do T.lift $ modify $ \ s -> s { shaderUsedSamplers = Map.insert name gDeclSampler $ shaderUsedSamplers s } 
                return $ 's':show name
    where
        gDeclSampler = do tellGlobal "sampler"
                          tellGlobal str
                          tellGlobal " s"
                          tellGlobalLn $ show name 

getNext :: Monad m => StateT Int m Int
getNext = do
    s <- get
    put $ s + 1
    return s

--getTempVar :: ExprM Int
--getTempVar = lift $ lift $ lift $ lift getNext
       
type RValue = String

tellAssignment :: SType -> ExprM RValue -> ExprM String
tellAssignment typ m = fmap head . memoizeM $ do
                                 val <- m
                                 var <- T.lift $ T.lift $ T.lift getNext
                                 let name = 't' : show var
                                 T.lift $ T.lift $ tell (stypeName typ ++ " ")
                                 tellAssignment' name val
                                 return [name]

tellAssignment' :: String -> RValue -> ExprM ()
tellAssignment' name string = T.lift $ T.lift $ tell $ mconcat [name, " = ", string, ";\n"]

discard :: FBool -> ExprM ()
discard (S m) = do b <- m
                   when (b /= "true") $ T.lift $ T.lift $ tell $ mconcat ["if (!(", b, ")) discard;\n"]
                                       
--
tellGlobalLn :: String -> GlobDeclM ()
tellGlobalLn string = tell $ string `mappend` ";\n"
--
tellGlobal :: String -> GlobDeclM ()
tellGlobal = tell

-----------------------

data ShaderBase a x where
    ShaderBaseFloat :: S x Float -> ShaderBase (S x Float) x 
    ShaderBaseInt :: S x Int -> ShaderBase (S x Int) x 
    ShaderBaseWord :: S x Word -> ShaderBase (S x Word) x 
    ShaderBaseBool :: S x Bool -> ShaderBase (S x Bool) x 
    ShaderBaseUnit :: ShaderBase () x 
    ShaderBaseProd :: ShaderBase a x -> ShaderBase b x -> ShaderBase (a,b) x 

shaderbaseDeclare :: ShaderBase a x -> WriterT [String] ExprM (ShaderBase a x)
shaderbaseAssign :: ShaderBase a x -> StateT [String] ExprM ()
shaderbaseReturn :: ShaderBase a x -> ReaderT (ExprM [String]) (State Int) (ShaderBase a x)

shaderbaseDeclare (ShaderBaseFloat _) = ShaderBaseFloat <$> shaderbaseDeclareDef STypeFloat
shaderbaseDeclare (ShaderBaseInt _) = ShaderBaseInt <$> shaderbaseDeclareDef STypeInt
shaderbaseDeclare (ShaderBaseWord _) = ShaderBaseWord <$> shaderbaseDeclareDef STypeUInt
shaderbaseDeclare (ShaderBaseBool _) = ShaderBaseBool <$> shaderbaseDeclareDef STypeBool
shaderbaseDeclare ShaderBaseUnit = return ShaderBaseUnit 
shaderbaseDeclare (ShaderBaseProd a b) = do a' <- shaderbaseDeclare a
                                            b' <- shaderbaseDeclare b
                                            return $ ShaderBaseProd a' b'

shaderbaseAssign (ShaderBaseFloat a) = shaderbaseAssignDef a
shaderbaseAssign (ShaderBaseInt a) = shaderbaseAssignDef a
shaderbaseAssign (ShaderBaseWord a) = shaderbaseAssignDef a
shaderbaseAssign (ShaderBaseBool a) = shaderbaseAssignDef a
shaderbaseAssign ShaderBaseUnit = return ()
shaderbaseAssign (ShaderBaseProd a b) = do shaderbaseAssign a
                                           shaderbaseAssign b

shaderbaseReturn (ShaderBaseFloat _) = ShaderBaseFloat <$> shaderbaseReturnDef
shaderbaseReturn (ShaderBaseInt _) = ShaderBaseInt <$> shaderbaseReturnDef
shaderbaseReturn (ShaderBaseWord _) = ShaderBaseWord <$> shaderbaseReturnDef
shaderbaseReturn (ShaderBaseBool _) = ShaderBaseBool <$> shaderbaseReturnDef
shaderbaseReturn ShaderBaseUnit = return ShaderBaseUnit 
shaderbaseReturn (ShaderBaseProd a b) = do a' <- shaderbaseReturn a
                                           b' <- shaderbaseReturn b
                                           return $ ShaderBaseProd a' b'

shaderbaseDeclareDef :: SType -> WriterT [String] ExprM (S x a)
shaderbaseDeclareDef styp = do var <- T.lift $ T.lift $ T.lift $ T.lift getNext
                               let root = 't' : show var
                               T.lift $ T.lift $ T.lift $ tell $ mconcat [stypeName styp, ' ':root, ";\n"]
                               tell [root]
                               return $ S $ return root

shaderbaseAssignDef  (S shaderM) = do ul <- T.lift shaderM
                                      x:xs <- get
                                      put xs
                                      T.lift $ tellAssignment' x ul
                                      return ()
shaderbaseReturnDef :: ReaderT (ExprM [String]) (State Int) (S x a)
shaderbaseReturnDef = do i <- T.lift getNext
                         m <- ask
                         return $ S $ fmap (!!i) m

    
class ShaderType a x where
    type ShaderBaseType a
    toBase :: x -> a -> ShaderBase (ShaderBaseType a) x
    fromBase :: x -> ShaderBase (ShaderBaseType a) x -> a
    
instance ShaderType (S x Float) x where
    type ShaderBaseType (S x Float) = (S x Float)
    toBase _ = ShaderBaseFloat
    fromBase _ (ShaderBaseFloat a) = a

instance ShaderType (S x Int) x where
    type ShaderBaseType (S x Int) = (S x Int)
    toBase _ = ShaderBaseInt
    fromBase _ (ShaderBaseInt a) = a
    
instance ShaderType (S x Word) x where
    type ShaderBaseType (S x Word) = (S x Word)
    toBase _ = ShaderBaseWord
    fromBase _ (ShaderBaseWord a) = a

instance ShaderType (S x Bool) x where
    type ShaderBaseType (S x Bool) = (S x Bool)
    toBase _ = ShaderBaseBool
    fromBase _ (ShaderBaseBool a) = a
    
instance ShaderType () x where
    type ShaderBaseType () = ()
    toBase _ () = ShaderBaseUnit
    fromBase _ ShaderBaseUnit = ()

instance (ShaderType a x, ShaderType b x) => ShaderType (a,b) x where
    type ShaderBaseType (a,b) = (ShaderBaseType a, ShaderBaseType b)
    toBase x ~(a,b) = ShaderBaseProd (toBase x a) (toBase x b)
    fromBase x (ShaderBaseProd a b) = (fromBase x a, fromBase x b)
instance (ShaderType a x, ShaderType b x, ShaderType c x) => ShaderType (a,b,c) x where
    type ShaderBaseType (a,b,c) = (ShaderBaseType a, (ShaderBaseType b, ShaderBaseType c))
    toBase x ~(a,b,c) = ShaderBaseProd (toBase x a) (ShaderBaseProd (toBase x b) (toBase x c))
    fromBase x (ShaderBaseProd a (ShaderBaseProd b c)) = (fromBase x a, fromBase x b, fromBase x c)
    
ifThenElse' :: forall a x. (ShaderType a x) => S x Bool -> a -> a -> a
ifThenElse' b t e = ifThenElse b (const t) (const e) ()

ifThenElse :: forall a b x. (ShaderType a x, ShaderType b x) => S x Bool -> (a -> b) -> (a -> b) -> a -> b
ifThenElse c t e i = fromBase x $ ifThenElse_ c (toBase x . t . fromBase x) (toBase x . e . fromBase x) (toBase x i)
    where
        x = undefined :: x
        ifThenElse_ :: S x Bool -> (ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType b) x) -> (ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType b) x) -> ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType b) x
        ifThenElse_ bool thn els a = 
            let ifM = memoizeM $ do
                           boolStr <- unS bool
                           (lifted, aDecls) <- runWriterT $ shaderbaseDeclare (toBase x (undefined :: a))
                           void $ evalStateT (shaderbaseAssign a) aDecls
                           decls <- execWriterT $ shaderbaseDeclare (toBase x (undefined :: b))
                           tellIf boolStr                
                           void $ evalStateT (shaderbaseAssign $ thn lifted) decls                                    
                           T.lift $ T.lift $ tell "} else {\n"                   
                           void $ evalStateT (shaderbaseAssign $ els lifted) decls
                           T.lift $ T.lift $ tell "}\n"                                                 
                           return decls
            in evalState (runReaderT (shaderbaseReturn (toBase x (undefined :: b))) ifM) 0

ifThen :: forall a x. (ShaderType a x) => S x Bool -> (a -> a) -> a -> a
ifThen c t i = fromBase x $ ifThen_ c (toBase x . t . fromBase x) (toBase x i)
    where
        x = undefined :: x
        ifThen_ :: S x Bool -> (ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType a) x) -> ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType a) x
        ifThen_ bool thn a = 
            let ifM = memoizeM $ do
                           boolStr <- unS bool
                           (lifted, decls) <- runWriterT $ shaderbaseDeclare (toBase x (undefined :: a))
                           void $ evalStateT (shaderbaseAssign a) decls
                           tellIf boolStr
                           void $ evalStateT (shaderbaseAssign $ thn lifted) decls                                    
                           T.lift $ T.lift $ tell "}\n"
                           return decls
            in evalState (runReaderT (shaderbaseReturn (toBase x (undefined :: a))) ifM) 0
    

tellIf :: RValue -> ExprM ()
tellIf boolStr = T.lift $ T.lift $ tell $ mconcat ["if(", boolStr, "){\n" ]
while :: forall a x. (ShaderType a x) => (a -> S x Bool) -> (a -> a) -> a -> a
while c f i = fromBase x $ while_ (c . fromBase x) (toBase x . f . fromBase x) (toBase x i)            
    where
        x = undefined :: x
        while_ :: (ShaderBase (ShaderBaseType a) x -> S x Bool) -> (ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType a) x) -> ShaderBase (ShaderBaseType a) x -> ShaderBase (ShaderBaseType a) x                                 
        while_ bool loopF a = let whileM = memoizeM $ do
                                           (lifted, decls) <- runWriterT $ shaderbaseDeclare (toBase x (undefined :: a))
                                           void $ evalStateT (shaderbaseAssign a) decls
                                           boolDecl <- tellAssignment STypeBool (unS $ bool a)
                                           T.lift $ T.lift $ tell $ mconcat ["while(", boolDecl, "){\n" ]
                                           let looped = loopF lifted                                
                                           void $ evalStateT (shaderbaseAssign looped) decls 
                                           loopedBoolStr <- unS $ bool looped
                                           tellAssignment' boolDecl loopedBoolStr
                                           T.lift $ T.lift $ tell "}\n"
                                           return decls
                             in evalState (runReaderT (shaderbaseReturn (toBase x (undefined :: a))) whileM) 0


--------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------


bin :: SType -> String -> S c x -> S c y -> S c z 
bin typ o (S a) (S b) = S $ tellAssignment typ $ do a' <- a
                                                    b' <- b
                                                    return $ '(' : a' ++ o ++ b' ++ ")"

fun1 :: SType -> String -> S c x -> S c y
fun1 typ f (S a) = S $ tellAssignment typ $ do a' <- a
                                               return $ f ++ '(' : a' ++ ")"

fun2 :: SType -> String -> S c x -> S c y -> S c z
fun2 typ f (S a) (S b) = S $ tellAssignment typ $ do a' <- a
                                                     b' <- b
                                                     return $ f ++ '(' : a' ++ ',' : b' ++ ")"

fun3 :: SType -> String -> S c x -> S c y -> S c z -> S c w
fun3 typ f (S a) (S b) (S c) = S $ tellAssignment typ $ do a' <- a
                                                           b' <- b
                                                           c' <- c
                                                           return $ f ++ '(' : a' ++ ',' : b' ++ ',' : c' ++")"

fun4 :: SType -> String -> S c x -> S c y -> S c z -> S c w -> S c r
fun4 typ f (S a) (S b) (S c) (S d) = S $ tellAssignment typ $ do a' <- a
                                                                 b' <- b
                                                                 c' <- c
                                                                 d' <- d
                                                                 return $ f ++ '(' : a' ++ ',' : b' ++ ',' : c' ++ ',' : d' ++")"

postop :: SType -> String -> S c x -> S c y
postop typ f (S a) = S $ tellAssignment typ $ do a' <- a
                                                 return $ '(' : a' ++ f ++ ")"
                          
preop :: SType -> String -> S c x -> S c y
preop typ f (S a) = S $ tellAssignment typ $ do a' <- a
                                                return $ '(' : f ++ a' ++ ")"

binf :: String -> S c x -> S c y -> S c Float
binf = bin STypeFloat
fun1f :: String -> S c x -> S c Float
fun1f = fun1 STypeFloat
fun2f :: String -> S c x -> S c y -> S c Float
fun2f = fun2 STypeFloat
fun3f :: String -> S c x -> S c y -> S c z -> S c Float
fun3f = fun3 STypeFloat
preopf :: String -> S c x -> S c Float
preopf = preop STypeFloat
postopf :: String -> S c x -> S c Float
postopf = postop STypeFloat

bini :: String -> S c x -> S c y -> S c Int
bini = bin STypeInt
fun1i :: String -> S c x -> S c Int
fun1i = fun1 STypeInt
preopi :: String -> S c x -> S c Int
preopi = preop STypeInt

binu :: String -> S c x -> S c y -> S c Word
binu = bin STypeUInt
fun1u :: String -> S c x -> S c Word
fun1u = fun1 STypeUInt
preopu :: String -> S c x -> S c Word
preopu = preop STypeUInt

-- TODO: Implement all numeric classes for float int and word

instance Num (S a Float) where
    (+) = binf "+"
    (-) = binf "-"
    abs = fun1f "abs"
    signum = fun1f "sign"
    (*) = binf "*"
    fromInteger = S . return . show
    negate = preopf "-"

instance Num (S a Int) where
    (+) = bini "+"
    (-) = bini "-"
    abs = fun1i "abs"
    signum = fun1i "sign"
    (*) = bini "*"
    fromInteger = S . return . show
    negate = preopi "-"
    
instance Num (S a Word) where
    (+) = binu "+"
    (-) = binu "-"
    abs = fun1u "abs"
    signum = fun1u "sign"
    (*) = binu "*"
    fromInteger x = S $ return $ show x ++ "u"
    negate = preopu "-"   

instance Fractional (S a Float) where
  (/)          = binf "/"
  fromRational = S . return . show . (`asTypeOf` (undefined :: Float)) . fromRational

instance Floating (S a Float) where
  pi    = S $ return $ show (pi :: Float)
  sqrt  = fun1f "sqrt"
  exp   = fun1f "exp"
  log   = fun1f "log"
  (**)  = fun2f "pow"
  sin   = fun1f "sin"
  cos   = fun1f "cos"
  tan   = fun1f "tan"
  asin  = fun1f "asin"
  acos  = fun1f "acos"
  atan  = fun1f "atan"
  sinh  = fun1f "sinh"
  cosh  = fun1f "cosh"
  asinh = fun1f "asinh"
  atanh = fun1f "atanh"
  acosh = fun1f "acosh"

instance Boolean (S a Bool) where
  true = S $ return "true"
  false = S $ return "false"
  notB  = preop STypeBool "!"
  (&&*) = bin STypeBool "&&"
  (||*) = bin STypeBool "||"

type instance BooleanOf (S a x) = S a Bool

instance Eq x => EqB (S a x) where
  (==*) = bin STypeBool "=="
  (/=*) = bin STypeBool "!="

instance Ord x => OrdB (S a x) where
  (<*) = bin STypeBool "<"
  (<=*) = bin STypeBool "<="
  (>=*) = bin STypeBool ">="
  (>*) = bin STypeBool ">"

instance IfB (S a x) where
        ifB (S c) (S t) (S e) = S $ tellAssignment STypeBool $ do c' <- c
                                                                  t' <- t
                                                                  e' <- e
                                                                  return $ '(' : c' ++ '?' : t' ++ ':' : e' ++")"
                                       
-- | This class provides the GPU functions either not found in Prelude's numerical classes, or that has wrong types.
--   Instances are also provided for normal 'Float's and 'Double's.
--   Minimal complete definition: 'floor'' or 'ceiling''.
class (IfB a, OrdB a, Floating a) => Real' a where
  rsqrt :: a -> a
  exp2 :: a -> a
  log2 :: a -> a
  floor' :: a -> a
  ceiling' :: a -> a
  fract' :: a -> a
  mod' :: a -> a -> a
  clamp :: a -> a -> a -> a
  saturate :: a -> a
  mix :: a -> a -> a-> a
  step :: a -> a -> a
  smoothstep :: a -> a -> a -> a

  rsqrt = (1/) . sqrt
  exp2 = (2**)
  log2 = logBase 2
  clamp x a = minB (maxB x a)
  saturate x = clamp x 0 1
  mix x y a = x*(1-a)+y*a
  step a x = ifB (x <* a) 0 1
  smoothstep a b x = let t = saturate ((x-a) / (b-a))
                     in t*t*(3-2*t)
  fract' x = x - floor' x
  mod' x y = x - y* floor' (x/y)
  floor' x = -ceiling' (-x)
  ceiling' x = -floor' (-x)


instance Real' Float where
  clamp x a = min (max x a)
  step a x | x < a     = 0
           | otherwise = 1
  floor' = fromIntegral . floor
  ceiling' = fromIntegral . ceiling

instance Real' Double where
  clamp x a = min (max x a)
  step a x | x < a     = 0
           | otherwise = 1
  floor' = fromIntegral . floor
  ceiling' = fromIntegral . ceiling
  
instance Real' (S x Float) where
  rsqrt = fun1f "inversesqrt"
  exp2 = fun1f "exp2"
  log2 = fun1f "log2"
  floor' = fun1f "floor"
  ceiling' = fun1f "ceil"
  fract' = fun1f "fract"
  mod' = fun2f "mod"
  clamp = fun3f "clamp"
  mix = fun3f "mix"
  step = fun2f "step"
  smoothstep = fun3f "smoothstep"


-- | Provides a common way to convert numeric types to integer and floating point representations.
class Convert a where
    type ConvertFloat a
    type ConvertInt a
    type ConvertWord a
    -- | Convert to a floating point number.
    toFloat :: a -> ConvertFloat a
    -- | Convert to an integral number, using truncation if necessary.
    toInt :: a -> ConvertInt a
    -- | Convert to an unsigned integral number, using truncation if necessary.
    toWord :: a -> ConvertWord a

instance Convert Float where
    type ConvertFloat Float = Float
    type ConvertInt Float = Int
    type ConvertWord Float = Word
    toFloat = id
    toInt = truncate
    toWord = truncate
instance Convert Int where
    type ConvertFloat Int = Float
    type ConvertInt Int = Int
    type ConvertWord Int = Word
    toFloat = fromIntegral
    toInt = id
    toWord = fromIntegral
instance Convert Word where
    type ConvertFloat Word = Float
    type ConvertInt Word = Int
    type ConvertWord Word = Word
    toFloat = fromIntegral
    toInt = fromIntegral
    toWord = id
instance Convert (S x Float) where
    type ConvertFloat (S x Float) = S x Float
    type ConvertInt (S x Float) = S x Int
    type ConvertWord (S x Float) = S x Word
    toFloat = id
    toInt = fun1i "int"
    toWord = fun1u "uint"
instance Convert (S x Int) where
    type ConvertFloat (S x Int) = S x Float
    type ConvertInt (S x Int) = S x Int
    type ConvertWord (S x Int) = S x Word
    toFloat = fun1f "float"
    toInt = id
    toWord = fun1u "uint"
instance Convert (S x Word) where
    type ConvertFloat (S x Word) = S x Float
    type ConvertInt (S x Word) = S x Int
    type ConvertWord (S x Word) = S x Word
    toFloat = fun1f "float"
    toInt = fun1i "int"
    toWord = id
  
-- | The derivative in x using local differencing of the rasterized value.
dFdx :: FFloat -> FFloat
-- | The derivative in y using local differencing of the rasterized value.
dFdy :: FFloat -> FFloat
-- | The sum of the absolute derivative in x and y using local differencing of the rasterized value.
fwidth :: FFloat -> FFloat
dFdx = fun1f "dFdx"
dFdy = fun1f "dFdy"
fwidth = fun1f "fwidth"

---------------------------------
fromVec4 :: (S x Float, S x Float, S x Float, S x Float) -> S x (Float,Float,Float,Float)
fromVec4 (x,y,z,w) = S $ do params <- mapM unS [x,y,z,w]
                            return $ "vec4(" ++ intercalate "," params ++ ")"  
fromVec3 :: (S x Float, S x Float, S x Float) -> S x (Float,Float,Float)
fromVec3 (x,y,z) = S $ do params <- mapM unS [x,y,z]
                          return $ "vec3(" ++ intercalate "," params ++ ")"  
fromVec2 :: (S x Float, S x Float) -> S x (Float,Float)
fromVec2 (x,y) = S $ do params <- mapM unS [x,y]
                        return $ "vec2(" ++ intercalate "," params ++ ")"  
                              
length4 :: (S x Float, S x Float, S x Float, S x Float) -> S x Float
length4 = fun1f "length" . fromVec4
length3 :: (S x Float, S x Float, S x Float) -> S x Float
length3 = fun1f "length" . fromVec3
length2 :: (S x Float, S x Float) -> S x Float
length2 = fun1f "length" . fromVec2

normalize4 :: (S x Float, S x Float, S x Float, S x Float) -> (S x Float, S x Float, S x Float, S x Float)
normalize4 = vec4S'' . fun1 (STypeVec 4) "normalize" . fromVec4
normalize3 :: (S x Float, S x Float, S x Float) -> (S x Float, S x Float, S x Float)
normalize3 = vec3S'' . fun1 (STypeVec 3) "normalize" . fromVec3
normalize2 :: (S x Float, S x Float) -> (S x Float, S x Float)
normalize2 = vec2S'' . fun1 (STypeVec 2) "normalize" . fromVec2

dot4 :: (S x Float, S x Float, S x Float, S x Float) -> (S x Float, S x Float, S x Float, S x Float) -> S x Float
dot4 a b = fun2f "dot" (fromVec4 a) (fromVec4 b)
dot3 :: (S x Float, S x Float, S x Float) -> (S x Float, S x Float, S x Float) -> S x Float
dot3 a b = fun2f "dot" (fromVec3 a) (fromVec3 b)
dot2 :: (S x Float, S x Float) -> (S x Float, S x Float) -> S x Float
dot2 a b = fun2f "dot" (fromVec2 a) (fromVec2 b)

cross :: (S x Float, S x Float, S x Float) -> (S x Float, S x Float, S x Float) -> (S x Float, S x Float, S x Float)
cross a b = vec3S'' $ fun2 (STypeVec 3) "cross" (fromVec3 a) (fromVec3 b)

---------------------------------

{-# RULES "minB/S" minB = minS #-}
{-# RULES "maxB/S" maxB = maxS #-}
minS :: S x Float -> S x Float -> S x Float 
minS = binf "min"
maxS :: S x Float -> S x Float -> S x Float 
maxS = binf "max"

                             