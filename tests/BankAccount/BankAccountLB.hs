{-# LANGUAGE TemplateHaskell, ScopedTypeVariables #-}

import Codeec.Shim
import Codeec.ClientMonad
import Codeec.DBDriver
import BankAccountDefs
import Codeec.Contract
import System.Process (runCommand, terminateProcess)
import System.Environment (getExecutablePath, getArgs)
import Control.Concurrent (threadDelay)
import Codeec.NameService.Types
import Codeec.NameService.SimpleBroker
import Codeec.Marshall
import Codeec.TH
import Database.Cassandra.CQL
import Control.Monad.Trans (liftIO)
import Data.Text (pack)
import Codeec.Types (summarize)
import Control.Monad (replicateM_)

fePort :: Int
fePort = 5558

bePort :: Int
bePort = 5559


data Kind = B | C | S | D deriving (Read, Show)

keyspace :: Keyspace
keyspace = Keyspace $ pack "Codeec"

dtLib = mkDtLib [(Deposit, mkGenOp deposit summarize, $(checkOp Deposit depositCtrt)),
                 (Withdraw, mkGenOp withdraw summarize, $(checkOp Withdraw withdrawCtrt)),
                 (GetBalance, mkGenOp getBalance summarize, $(checkOp GetBalance getBalanceCtrt))]

main :: IO ()
main = do
  (kindStr:_) <- getArgs
  let k :: Kind = read kindStr
  let ns = mkNameService (Frontend $ "tcp://localhost:" ++ show fePort) (Backend $ "tcp://localhost:" ++ show bePort) "localhost" 5560
  case k of
    B -> startBroker (Frontend $ "tcp://*:" ++ show fePort)
                     (Backend $ "tcp://*:" ++ show bePort)
    S -> do
      runShimNode dtLib [("localhost","9042")] keyspace ns
    C -> runSession ns $ do
      key <- liftIO $ newKey

      replicateM_ 8192 $ do
        r::() <- invoke key Deposit (1::Int)
        r :: Int <- invoke key GetBalance ()
        liftIO . putStrLn $ show r
    D -> do
      pool <- newPool [("localhost","9042")] keyspace Nothing
      runCas pool $ createTable "BankAccount"
      progName <- getExecutablePath
      putStrLn "Driver : Starting broker"
      b <- runCommand $ progName ++ " B"
      putStrLn "Driver : Starting server"
      s <- runCommand $ progName ++ " S"
      putStrLn "Driver : Starting client"
      c <- runCommand $ progName ++ " C"
      threadDelay 10000000
      mapM_ terminateProcess [b,s,c]
      runCas pool $ dropTable "BankAccount"
