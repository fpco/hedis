{-# LANGUAGE RecordWildCards, DeriveDataTypeable #-}

-- |A module for automatic, optimal protocol pipelining.
--
--  Protocol pipelining is a technique in which multiple requests are written
--  out to a single socket without waiting for the corresponding responses.
--  The pipelining of requests results in a dramatic improvement in protocol
--  performance.
--
--  [Optimal Pipelining] uses the least number of network packets possible
--
--  [Automatic Pipelining] means that requests are implicitly pipelined as much
--      as possible, i.e. as long as a request's response is not used before any
--      subsequent requests.
--
--  We use a BoundedChan to make sure the evaluator thread can only start to
--  evaluate a reply after the request is written to the output buffer.
--  Otherwise we will flush the output buffer (in hGetReplies) before a command
--  is written by the user thread, creating a deadlock.
--
--
--  # Notes
--
--  [Eval thread synchronization]
--      * BoundedChan performs better than Control.Concurrent.STM.TBQueue
--
module Database.Redis.ProtocolPipelining (
    Connection,
    connect, disconnect, request, send, recv,
    ConnectionLostException(..),
    HostName, PortID(..)
) where

import           Prelude hiding (catch)
import           Control.Concurrent (ThreadId, forkIO, killThread)
import           Control.Concurrent.BoundedChan
import           Control.Exception
import           Control.Monad
import           Data.Attoparsec
import qualified Data.ByteString as S
import           Data.IORef
import           Data.Typeable
import           Network
import           System.IO
import           System.IO.Error (isEOFError)
import           System.IO.Unsafe


data Connection a = Conn
    { connHandle   :: Handle        -- ^ Connection socket-handle.
    , connOutput   :: BoundedChan a -- ^ See note [Eval thread synchronization].
    }

data ConnectionLostException = ConnectionLost IOException
    deriving (Show, Typeable)

instance Exception ConnectionLostException

connect
    :: HostName
    -> PortID
    -> Parser a
    -> IO (Connection a)
connect host port parser = do
    connHandle  <- connectTo host port
    hSetBinaryMode connHandle True
    connOutput  <- newBoundedChan 1000
    _ <- forkIO $ hGetReplies connHandle parser (writeChan connOutput)
    return Conn{..}

disconnect :: Connection a -> IO ()
disconnect = hClose . connHandle

-- |Write the request to the socket output buffer.
--
--  The 'Handle' is 'hFlush'ed when reading replies.
send :: Connection a -> S.ByteString -> IO ()
send Conn{..} = S.hPut connHandle

-- |Take a reply from the list of future replies.
--
--  The list of thunks must be deconstructed lazily, i.e. strictly matching (:)
--  would block until a reply can be read. Using 'head' and 'tail' achieves ~2%
--  more req/s in pipelined code than a lazy pattern match @~(r:rs)@.
recv :: Connection a -> IO a
recv = readChan . connOutput

request :: Connection a -> S.ByteString -> IO a
request conn req = send conn req >> recv conn

-- |Read all the replies from the Handle and return them as a lazy list.
--
--  The actual reading and parsing of each 'Reply' is deferred until the spine
--  of the list is evaluated up to that 'Reply'. Each 'Reply' is cons'd in front
--  of the (unevaluated) list of all remaining replies.
--
--  'unsafeInterleaveIO' only evaluates it's result once, making this function 
--  thread-safe. 'Handle' as implemented by GHC is also threadsafe, it is safe
--  to call 'hFlush' here. The list constructor '(:)' must be called from
--  /within/ unsafeInterleaveIO, to keep the replies in correct order.
hGetReplies :: Handle -> Parser a -> (a -> IO ()) -> IO ()
hGetReplies h parser yield =
    go S.empty
  where
    go rest = do
        parseResult <- parseWith readMore parser rest
        case parseResult of
            Fail{}       -> error "Hedis: parse failure"
            Partial{}    -> error "Hedis: parseWith returned Partial"
            Done rest' r -> do
                yield r
                go rest'

    readMore = do
        hFlush h -- send any pending requests
        S.hGetSome h maxRead `catch` errConnClosed

    maxRead       = 4*1024
    errConnClosed e
        | isEOFError e = return S.empty
        | otherwise    = throwIO (ConnectionLost e)
