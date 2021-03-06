#!/usr/bin/env runhaskell
import Control.Monad
import System.Random

import Text.Printf

main :: IO ()
main = replicateM_ 1000 $ do
  x <- randomRIO (-4, 4)
  y <- randomRIO (-4, 4)
  let z :: Double
      z = cos(y) - sin(x)
  printf "%d 1:%f 2:%f\n" (abs (floor z)::Int) x y

{-
 Try the following command.

 ./exe-src/libsvm-test.hs > testdata.txt
 ./exe-src/libsvm-test.hs > testdata2.txt
 ./libsvm/easy.py testdata.txt  testdata2.txt

-}