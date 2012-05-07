module Puppet.Printers where

import Puppet.Interpreter.Types

showRes (CResource crid rname rtype params relations virtuality pos) = putStrLn $ rtype ++ " " ++ show rname
