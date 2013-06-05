{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
module Main where

import           Control.Applicative
import           Control.DeepSeq (deepseq, NFData(..), force)
import           Control.Lens ((^.), Lens')
import qualified Control.Lens as Lens
import           Control.Monad
import           Control.Monad.IO.Class (liftIO, MonadIO)
import qualified Data.Array.Repa as Repa
import qualified Data.Array.Repa.Eval as Repa
import           Data.Array.Repa.Index 
import           Data.Data
import           Data.String.Utils (replace)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM
import           Filesystem.Path.CurrentOS (decodeString)
import           GHC.Float (double2Float)
import           Graphics.ImageMagick.MagickWand
import           System.Console.CmdArgs.Implicit ((&=))
import qualified System.Console.CmdArgs.Implicit as Cmd
import           System.Environment
import           System.IO
import           System.IO.Unsafe
import           System.Process
import           System.Random
import           Text.Printf


readInteractiveCommand :: String -> IO String
readInteractiveCommand cmd = do
  (_, stdout, _, _) <- runInteractiveCommand cmd
  hGetContents stdout


data Option = Option { useMinMax :: Bool, patternSize :: Int}
  deriving (Eq, Show, Typeable, Data)

optionParser :: Option
optionParser = Option Cmd.def Cmd.def 

outputFolder :: Option -> String
outputFolder Option{..} = printf "result-%d-%d" (if useMinMax then 1 else 0::Int) patternSize

{-# NOINLINE myOption #-}
myOption :: Option
myOption = unsafePerformIO $ Cmd.cmdArgs optionParser


newtype RGBA a = RGBA {unRGBA :: (a,a,a,a)} deriving (Eq, Show, Functor)
deriving instance (VG.Vector VU.Vector a, VUM.Unbox a) => VG.Vector VU.Vector (RGBA a)
deriving instance (VGM.MVector VU.MVector a, VUM.Unbox a) => VGM.MVector VU.MVector (RGBA a)
deriving instance (VUM.Unbox a) => VUM.Unbox (RGBA a)
deriving instance (Repa.Elt a) => Repa.Elt (RGBA a)

instance (NFData a) => NFData (RGBA a) where
  rnf (RGBA a4) = rnf a4 `seq` ()

{-# INLINE isoRGBA #-}
isoRGBA :: Lens.Iso' (RGBA a) (a,a,a,a)
isoRGBA = Lens.iso unRGBA RGBA


red, green, blue, alpha :: Lens' (RGBA a) a
{-# INLINE red #-} 
red = isoRGBA . Lens._1
{-# INLINE green #-} 
green = isoRGBA . Lens._2
{-# INLINE blue #-} 
blue = isoRGBA . Lens._3
{-# INLINE alpha #-}
alpha = isoRGBA . Lens._4

{-# INLINE rgba #-}
rgba r g b a = RGBA (r,g,b,a)

{-# INLINE zipRGBAWith #-}
zipRGBAWith :: (NFData a) => (a->a->a) -> RGBA a -> RGBA a -> RGBA a 
zipRGBAWith f (RGBA (r0,b0,g0,a0)) (RGBA (r1,b1,g1,a1)) = 
  force $ rgba (r0`f`r1) (g0`f`g1) (b0`f`b1) (a0`f`a1)

instance (NFData a, Num a) => Num (RGBA a) where
  {-# INLINE fromInteger #-}
  fromInteger n' = force $ let n = fromInteger n' in rgba n n n n
  {-# INLINE (+) #-}
  (+) = zipRGBAWith (+)
  {-# INLINE (-) #-}
  (-) = zipRGBAWith (-)
  (*) = error "cannot multiply"
  {-# INLINE negate #-}
  negate = force $ fmap negate
  abs = error "cannot abs"
  signum = error "cannot sig"

type Picture a = Repa.Array Repa.U DIM2 a
type ColorPicture = Picture (RGBA Float)


at :: (VUM.Unbox a, Num a) => Picture a -> DIM2 -> a
at pict pt@(Z :. x :. y)
  | x <  0    = 0
  | y <  0    = 0
  | x >= w    = 0
  | y >= h    = 0
  | otherwise = Repa.unsafeIndex pict pt
  where
    (Z :. w :. h) =  Repa.extent pict

computeQuadTree :: forall a. (VUM.Unbox a, Num a) => 
                  ([a] -> a) ->
                  Picture a -> IO [Picture a]
computeQuadTree reduction pict = do
  let (Z :. w0 :. h0) =  Repa.extent pict
  if | w0 <= 8 -> return [pict]
     | h0 <= 8 -> return [pict]
     | otherwise -> do
       let w = w0 `div` 2; h = h0 `div` 2
           gen :: DIM2 -> a
           gen (Z :. x :. y) = reduction $ map (at pict) $
             ix2 <$> [2*x, 2*x+1] <*> [2*y, 2*y+1]
       nextPict <- Repa.computeP $ Repa.fromFunction
         (ix2 w h) gen
       fmap (pict:) $ computeQuadTree reduction nextPict

traverseQuadTree :: (VUM.Unbox a, Num a) => DIM2 -> [Picture a] -> [a]
traverseQuadTree pt@(Z :. x :. y) pics = case pics of
  [] -> []
  (pic:restOfPics) -> 
    map (at pic) pts ++ traverseQuadTree (ix2 (x`div`2) (y`div`2)) restOfPics
      where
        pts = [ix2 x' y' | y' <- [y-n .. y+n], x' <- [x-n .. x+n]]
        n = patternSize myOption                           


data SunspotClass = NotSunspot | SunspotA | SunspotB | SunspotBG | SunspotBGD
  deriving (Eq, Ord, Show, Enum)

sscOf :: (Fractional a, Ord a) => Lens.Iso' (RGBA a) SunspotClass
sscOf = Lens.iso to fro 
  where
    to (RGBA (r,g,b,_))
       | r <  0.5 && g <  0.5 && b >= 0.5 = SunspotA
       | r <  0.5 && g >= 0.5 && b <  0.5 = SunspotB
       | r >= 0.5 && g >= 0.5 && b <  0.5 = SunspotBG
       | r >= 0.5 && g <  0.5 && b <  0.5 = SunspotBGD
       | otherwise                        = NotSunspot
    fro NotSunspot = rgba 1 1 1 1
    fro SunspotA   = rgba 0 0 1 1
    fro SunspotB   = rgba 0 1 0 1
    fro SunspotBG  = rgba 1 1 0 1
    fro SunspotBGD = rgba 1 0 0 1
    


loadColorPicture :: FilePath -> IO ColorPicture
loadColorPicture fn = withMagickWandGenesis $ do
  (_,img) <- magickWand
  readImage img $ decodeString fn
  w <- getImageWidth img
  h <- getImageWidth img
  liftIO $ printf "%s (%d, %d)\n" fn w h

  pxl <- pixelWand
  pixels <- liftIO $ VUM.new (h*w) 

  forM_ [0..(h*w-1)] $ \idx -> do
     let (y,x) = idx `divMod` w
     getImagePixelColor img x y pxl
     r0 <- getRed pxl
     g0 <- getGreen pxl
     b0 <- getBlue pxl
     a0 <- getAlpha pxl
     liftIO $ VUM.write pixels idx $ fmap double2Float $ rgba r0 g0 b0 a0

  pixelsF <- liftIO $ VU.freeze pixels

  return $ Repa.fromUnboxed (ix2 w h) pixelsF


inputFns :: [(String,String)]
inputFns = [ ("20120123_hmi.png","20120123_hmi_mask.png")
           , ("20120307_hmi.png","20120307_hmi_mask.png")
           , ("20130515_11745_hmi.png","20130515_11745_hmi_mask.png")]

toFeatureFn :: String -> String
toFeatureFn fn = outputFolder myOption ++ "/" ++ replace ".png" ".txt" fn

main :: IO ()
main = do
  print myOption
  _ <- system $ "mkdir -p " ++ outputFolder myOption
  mapM_ process inputFns
  
  let featureFns = map (toFeatureFn . fst) $init inputFns
      trainFiles = init featureFns
      validFiles = [last featureFns]

      trainCatFile  = toFeatureFn "train.txt"
      validCatFile  = toFeatureFn "validate.txt"
  
      logFile = toFeatureFn "libsvm-easy.log"

  _ <- system $ printf "cat %s > %s" (unwords trainFiles) trainCatFile
  _ <- system $ printf "cat %s > %s" (unwords validFiles) validCatFile
  ret <- readInteractiveCommand$ printf "./libsvm/easy.py %s %s" trainCatFile validCatFile 
  writeFile logFile ret

  return ()

process :: (String,String) -> IO ()
process (imageFn, maskFn) = do
  pictSun <- loadColorPicture $ "data-shrunk/" ++ imageFn
  let (Z :. w :. h) = Repa.extent pictSun
      featureFn = toFeatureFn imageFn

  pictMask <- loadColorPicture $ "data-shrunk/" ++ maskFn



  classedSun <- Repa.computeP $ Repa.map (fromEnum . (^. sscOf)) pictMask
                :: IO (Picture Int)

  forM_ [0..4] $ \classIdx -> do
    cnt <- Repa.foldAllP (+) (0::Int) $ Repa.map (\i -> if i==classIdx then 1 else 0) classedSun
    printf "class %d: %08d\n" classIdx cnt

  avgTree <- computeQuadTree (fmap (/4) . sum) pictSun
  minTree <- computeQuadTree (foldr1 (zipRGBAWith min)) pictSun
  maxTree <- computeQuadTree (foldr1 (zipRGBAWith max)) pictSun

  
  featureBulk <- forM [0, 2 .. h-1] $ \y -> do
    forM [0, 2 .. w-1] $ \x -> do
      let pt = ix2 x y
          classNum = Repa.index classedSun pt
          
          useTree :: [ColorPicture] -> [Float]
          useTree = map (^.red) . traverseQuadTree pt 

          fvec0 = useTree avgTree

          fvec1 = if useMinMax myOption 
                  then useTree minTree ++ useTree maxTree
                  else []

          featureStr :: String
          featureStr = unwords $ zipWith (printf "%d:%f") [(1::Int)..] $ fvec0++fvec1

      sparser <- randomRIO (0,29 :: Int)
      let outputFlag = if classNum==0 then sparser==0 else True
      
      return $ case outputFlag of
        False -> ""
        True  -> Text.pack $ printf "%d %s\n" classNum featureStr
  Text.writeFile featureFn $ Text.concat $ concat featureBulk
  
