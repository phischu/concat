{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -Wno-orphans #-} -- TEMP

-- | Generate Verilog code from a circuit graph

module ConCat.Hardware.Verilog
  ( genVerilog,runVerilog
  ) where

import Data.List        (intercalate, (\\), intersect)
import System.Directory (createDirectoryIfMissing)
import Text.PrettyPrint (render)

import Language.Netlist.AST
import Language.Netlist.Util
import Language.Netlist.GenVerilog
import Language.Verilog.PrettyPrint

import ConCat.Circuit
  (Bus(..),GenBuses,busTy,(:>),simpleComp,mkGraph,CompS(..),systemSuccess)
import qualified ConCat.Circuit as C

effectVerilog :: (GenBuses a, GenBuses b) => String -> (a :> b) -> String
effectVerilog name circ = unlines $
  [ "/***"
  , "* Automatically generated Verilog code. Do not edit."
  , "*"
  , "* This code was generated by the Haskell ConCat library, via compiling to categories."
  , "***/"
  , render $ ppModule $ mk_module (verilog name circ)
  ]

genVerilog :: (GenBuses a, GenBuses b) => String -> (a :> b) -> IO ()
genVerilog name circ =
  do createDirectoryIfMissing False outDir
     let o = outFile name
     writeFile o (effectVerilog name circ)
     putStrLn ("Wrote " ++ o)

runVerilog :: (GenBuses a, GenBuses b) => String -> (a :> b) -> IO ()
runVerilog name circ =
  do genVerilog name circ
     -- systemSuccess $ printf "%s %s" open (outFile name)

outDir :: String
outDir = "out"

outFile :: String -> String
outFile name = outDir++"/"++name++".v"

-- Generate Verilog code for a circuit.
verilog :: (GenBuses a, GenBuses b) => String -> (a :> b) -> Module
verilog name  = mkModule name
              . fmap simpleComp
              . mkGraph
-- TODO: Abstract fmap simpleComp . mkGraph, which also appears in Show (a :> b)
-- and SMT and GLSL.

mkModule :: String -> [CompS] -> Module
mkModule name cs = Module name (f modIns) (f modOuts) [] (map busToNet modNets ++ map mkAssignment cs)
  where
    f xs    = [ (x, makeRange Down sz) | (x, sz) <- map busId' xs ]
    modIns  = allIns  \\ allOuts
    modOuts = allOuts \\ allIns
    modNets = allIns `intersect` allOuts
    allIns  = concatMap compIns  cs'
    allOuts = concatMap compOuts cs'
    cs'     = filter (flip notElem ["In", "Out"] . compName) cs

busId' :: Bus -> (String, Int)
busId' (Bus cId ix ty) = ('n' : show cId ++ ('_' : show ix), width)
  where width = case ty of
                  C.Unit     -> 0
                  C.Bool     -> 1
                  C.Int      -> 32
                  C.Float    -> 32
                  C.Double   -> 64
                  C.Arr _ _  -> error "ConCat.Hardware.Verilog.busId': Don't know what to do with Bus of type Arr, yet."
                  C.Prod _ _ -> error "ConCat.Hardware.Verilog.busId': Don't know what to do with Bus of type Prod, yet."
                  C.Sum _ _  -> error "ConCat.Hardware.Verilog.busId': Don't know what to do with Bus of type Sum, yet."
                  C.Fun _ _  -> error "ConCat.Hardware.Verilog.busId': Don't know what to do with Bus of type Fun, yet."


busName :: Bus -> String
busName  = fst . busId'

busWidth :: Bus -> Int
busWidth = snd . busId'

busToNet :: Bus -> Decl
busToNet b = NetDecl (busName b) (makeRange Down width) Nothing
  where width = busWidth b

mkAssignment :: CompS -> Decl
mkAssignment c | [o] <- outs = assign o prim ins
               | otherwise   = CommentDecl $ prim ++ ": o: " ++ intercalate ", " outs ++ ", ins: " ++ intercalate ", " ins
  where prim   = compName c
        ins    = map busName $ compIns  c
        outs   = map busName $ compOuts c

assign :: String -> String -> [String] -> Decl
assign o prim ins =
  case prim of
    "not"    -> assignUnary  LNeg
    "&&"     -> assignBinary LAnd
    "||"     -> assignBinary LOr
    "<"      -> assignBinary LessThan
    ">"      -> assignBinary GreaterThan
    "<="     -> assignBinary LessEqual
    ">="     -> assignBinary GreaterEqual
    "=="     -> assignBinary Equals
    "/="     -> assignBinary NotEquals
    "negate" -> assignUnary  Neg
    "+"      -> assignBinary Plus
    "-"      -> assignBinary Minus
    "−"      -> assignBinary Minus
    "*"      -> assignBinary Times
    "/"      -> assignBinary Divide
    "mod"    -> assignBinary Modulo
    "xor"    -> assignBinary Xor
    "if"     -> assignConditional
    "In"     -> CommentDecl $ "In: o: " ++ o ++ ", ins: " ++ intercalate ", " ins
    "Out"    -> CommentDecl $ "Out: o: " ++ o ++ ", ins: " ++ intercalate ", " ins
    _ | i <- fromIntegral (read prim) -> NetAssign o $ ExprLit (Just 32) (ExprNum i)
      | otherwise -> error $ "ConCat.Hardware.Verilog.assign: Received unrecognized primitive: " ++ prim
  where
    assignUnary op
      | [in1]      <- ins = NetAssign o $ ExprUnary op (ExprVar in1)
      | otherwise         = error $ errStr "unary"
    assignBinary op
      | [in1, in2] <- ins = NetAssign o $ ExprBinary op (ExprVar in1) (ExprVar in2)
      | otherwise         = error $ errStr "binary"
    assignConditional
      | [p, t, f]  <- ins = NetAssign o $ ExprCond (ExprVar p) (ExprVar t) (ExprVar f)
      | otherwise         = error $ errStr "conditional"
    errStr _ = "ConCat.Hardware.Verilog.assign: I received an incorrect number of inputs.\n"

-- These are, currently, commented out of ConCat/Circuit.hs.
-- compId :: CompS -> CompId
-- compId :: CompS -> Int
-- compId (CompS n _ _ _) = n
-- compName :: CompS -> PrimName
compName :: CompS -> String
compName (CompS _ nm _ _) = nm
-- compIns :: CompS -> [Input]
compIns :: CompS -> [Bus]
compIns (CompS _ _ ins _) = ins
-- compOuts :: CompS -> [Output]
compOuts :: CompS -> [Bus]
compOuts (CompS _ _ _ outs) = outs

