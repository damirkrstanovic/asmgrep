-- haskgrep_std_mt_tuned - idiomatic Haskell + threaded RTS + prefix binary-check.
--
-- Tuning vs grep_mt.hs (the "memory / I/O strategy" pillar):
--   * PREFIX CHECK: open the file, read only a 64 KB prefix (hGet h 65536),
--     NUL-check THAT, and read the rest only if the prefix is clean. Binary
--     files (NUL in the first 64 KB) cost one 64 KB read instead of slurping
--     the whole file -- "don't read data you'll skip".
--
-- BUFFER REUSE -- DELIBERATE DEVIATION:
--   The "reuse one mutable buffer per thread" pillar (as done in the C/Zig/Odin
--   tuned tiers) is NOT idiomatic in Haskell: Data.ByteString is immutable, and
--   any ByteString we hand to breakSubstring / hPutBuilder must own its bytes.
--   hGetBuf into a shared mallocForeignPtrBytes buffer would force us to either
--   (a) re-slurp into a fresh ByteString anyway (no saving), or (b) hand out
--   aliased views of a buffer that the next file's read would overwrite while a
--   prior file's output Builder still references it -- a correctness hazard with
--   concurrent workers. So this variant keeps the prefix-check win (the required
--   one) and does NOT do per-thread buffer reuse. The allocation per file is the
--   prefix (<=64 KB) plus, for text files, the remainder -- still one fresh
--   allocation per file, same as grep_mt, minus the wasted read on binaries.
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import           Data.ByteString (ByteString)
import           Data.Word (Word8)
import           Data.IORef
import           Control.Concurrent (forkIO)
import           Control.Concurrent.MVar
import           Control.Monad (when, unless, replicateM_, forM_)
import           Control.Exception (bracket)
import           GHC.Conc (getNumCapabilities)
import           System.Environment (getArgs)
import           System.Exit (exitWith, ExitCode (..))
import           System.IO
import           System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import           System.FilePath ((</>))
import qualified Data.ByteString.Char8 as BC
import           Data.Array (Array, listArray, (!))

data Cfg = Cfg
  { cfgPat   :: !ByteString
  , cfgLPat  :: !ByteString
  , cfgCI    :: !Bool
  , cfgMulti :: !Bool
  }

asciiLower :: ByteString -> ByteString
asciiLower = BS.map (\b -> if b >= 65 && b <= 90 then b + 32 else b)

nul, nl :: Word8
nul = 0
nl  = 10

prefixSize :: Int
prefixSize = 65536

-- Read with the prefix binary-check: pull the first 64 KB, NUL-check it, and
-- only read the rest when the prefix is clean. Returns Nothing for binary.
readChecked :: FilePath -> IO (Maybe ByteString)
readChecked path =
  bracket (openBinaryFile path ReadMode) hClose $ \h -> do
    prefix <- BS.hGet h prefixSize
    if BS.elem nul prefix
      then return Nothing                     -- binary: stop after one read
      else if BS.length prefix < prefixSize
             then return (Just prefix)         -- whole file fit in the prefix
             else do
               rest <- BS.hGetContents h       -- read remainder only now
               return (Just (prefix <> rest))

searchFile :: Cfg -> FilePath -> IO (Bool, BB.Builder)
searchFile cfg path = do
  mdat <- readChecked path
  case mdat of
    Nothing  -> return (False, mempty)        -- binary, skip
    Just dat -> do
      let len = BS.length dat
          (hay, needle)
            | cfgCI cfg = (asciiLower dat, cfgLPat cfg)
            | otherwise = (dat, cfgPat cfg)
          prefix = if cfgMulti cfg
                     then BB.byteString (BC.pack path) <> BB.word8 58
                     else mempty
          go !pos !matched !acc
            | pos >= len = (matched, acc)      -- pos < len guard (empty-pattern fix)
            | otherwise =
                let (pre, post) = BS.breakSubstring needle (BS.drop pos hay)
                in if BS.null post
                     then (matched, acc)
                     else
                       let m  = pos + BS.length pre
                           ls = case BS.elemIndexEnd nl (BS.take m dat) of
                                  Just i  -> i + 1
                                  Nothing -> 0
                           le = case BS.elemIndex nl (BS.drop m dat) of
                                  Just j  -> m + j
                                  Nothing -> len
                           line = BB.byteString (BS.take (le - ls) (BS.drop ls dat))
                           acc' = acc <> prefix <> line <> BB.word8 nl
                       in go (le + 1) True acc'
      return (go 0 False mempty)

walk :: FilePath -> IORef [FilePath] -> IO ()
walk top acc = collect top
  where
    collect q = do
      isLink <- pathIsSymbolicLink q
      unless isLink $ do
        isDir <- doesDirectoryExist q
        if isDir
          then listDirectory q >>= mapM_ (\e -> collect (q </> e))
          else modifyIORef' acc (q :)

usage :: IO a
usage = do
  hPutStr stderr "usage: haskgrep [-r] [-i] PATTERN PATH...\n"
  exitWith (ExitFailure 2)

parseArgs :: [String] -> Maybe (Bool, Bool, ByteString, [FilePath])
parseArgs = go False False Nothing [] False
  where
    go ci rec mpat paths _ [] =
      case mpat of
        Just pat | not (null paths) -> Just (ci, rec, pat, reverse paths)
        _                           -> Nothing
    go ci rec mpat paths noMore (a:as)
      | not noMore && a == "--" = go ci rec mpat paths True as
      | not noMore && length a >= 2 && head a == '-' =
          case parseFlags ci rec (tail a) of
            Just (ci', rec') -> go ci' rec' mpat paths noMore as
            Nothing          -> Nothing
      | Nothing <- mpat = go ci rec (Just (BC.pack a)) paths noMore as
      | otherwise       = go ci rec mpat (a : paths) noMore as
    parseFlags ci rec [] = Just (ci, rec)
    parseFlags ci rec (c:cs) = case c of
      'i' -> parseFlags True rec cs
      'r' -> parseFlags ci True cs
      _   -> Nothing

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Nothing -> usage
    Just (ci, recursive, pat, paths) -> do
      hSetBinaryMode stdout True
      hSetBuffering stdout (BlockBuffering (Just 65536))
      let multi = recursive || length paths > 1
          cfg = Cfg pat (asciiLower pat) ci multi
      fileAcc <- newIORef []
      forM_ paths $ \p -> do
        isDir <- doesDirectoryExist p
        if isDir
          then when recursive (walk p fileAcc)
          else modifyIORef' fileAcc (p :)
      files <- reverse <$> readIORef fileAcc
      let n = length files
      if n == 0
        then exitWith (ExitFailure 1)
        else do
          let arr = listArray (0, n - 1) files :: Array Int FilePath
          idxRef   <- newIORef 0
          matchRef <- newIORef False
          outLock  <- newMVar ()
          caps     <- getNumCapabilities
          let workers = max 1 (min caps n)
          done    <- newMVar (0 :: Int)
          allDone <- newEmptyMVar
          let worker = loop
                where
                  loop = do
                    i <- atomicModifyIORef' idxRef (\k -> (k + 1, k))
                    if i >= n
                      then modifyMVar_ done $ \d -> do
                             let d' = d + 1
                             when (d' == workers) (putMVar allDone ())
                             return d'
                      else do
                        (m, bldr) <- searchFile cfg (arr ! i)
                        when m $ do
                          writeIORef matchRef True
                          withMVar outLock $ \_ -> BB.hPutBuilder stdout bldr
                        loop
          replicateM_ workers (forkIO worker)
          takeMVar allDone
          hFlush stdout
          matched <- readIORef matchRef
          exitWith (if matched then ExitSuccess else ExitFailure 1)
