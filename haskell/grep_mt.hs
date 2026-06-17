-- haskgrep_std_mt - idiomatic Haskell + naive threads (threaded RTS).
-- Collect the full file list first, then fork one worker per capability
-- (-N from rtsopts) pulling file indices off a shared atomicModifyIORef'
-- counter. Each file is read IN FULL via BS.readFile (a fresh allocation
-- per file -- deliberately allocation-heavy tier; no buffer reuse, no
-- prefix-only read). Per-file output block is serialized under an MVar so
-- lines from different files never interleave (cross-file order unspecified).
module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import           Data.ByteString (ByteString)
import           Data.Word (Word8)
import           Data.IORef
import           Control.Concurrent (forkIO)
import           Control.Concurrent.MVar
import           Control.Monad (when, unless, replicateM_, forM_)
import           GHC.Conc (getNumCapabilities)
import           System.Environment (getArgs)
import           System.Exit (exitWith, ExitCode (..))
import           System.IO
import           System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import           System.FilePath ((</>))
import qualified Data.ByteString.Char8 as BC
import           Data.Array (Array, listArray, bounds, (!))

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

-- Build the output block for one file; return (matched?, builder).
-- Builder lets us assemble the whole block, then hold the stdout lock once.
searchFile :: Cfg -> FilePath -> IO (Bool, BB.Builder)
searchFile cfg path = do
  dat <- BS.readFile path                  -- FULL read, fresh allocation
  let len  = BS.length dat
      peek = min len 65536
  if BS.elem nul (BS.take peek dat)
    then return (False, mempty)            -- binary, skip
    else do
      let (hay, needle)
            | cfgCI cfg = (asciiLower dat, cfgLPat cfg)
            | otherwise = (dat, cfgPat cfg)
          prefix = if cfgMulti cfg
                     then BB.byteString (BC.pack path) <> BB.word8 58
                     else mempty
          go !pos !matched !acc
            | pos >= len = (matched, acc)  -- pos < len guard (empty-pattern fix)
            | otherwise =
                let (pre, post) = BS.breakSubstring needle (BS.drop pos hay)
                in if BS.null post
                     then (matched, acc)   -- not found / empty needle exhausted
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

walk :: Cfg -> FilePath -> IORef [FilePath] -> IO ()
walk _ p acc = collect p
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
      -- Gather the work list (regular files only).
      fileAcc <- newIORef []
      forM_ paths $ \p -> do
        isDir <- doesDirectoryExist p
        if isDir
          then when recursive (walk cfg p fileAcc)
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
          done <- newMVar (0 :: Int)         -- completion counter
          allDone <- newEmptyMVar
          let worker = loop
                where
                  loop = do
                    i <- atomicModifyIORef' idxRef (\k -> (k + 1, k))
                    if i >= n
                      then finish
                      else do
                        (m, bldr) <- searchFile cfg (arr ! i)
                        -- emit under the lock (skip empty blocks)
                        when m $ do
                          writeIORef matchRef True
                          withMVar outLock $ \_ -> BB.hPutBuilder stdout bldr
                        loop
                  finish = modifyMVar_ done $ \d -> do
                    let d' = d + 1
                    when (d' == workers) (putMVar allDone ())
                    return d'
          replicateM_ workers (forkIO worker)
          takeMVar allDone
          hFlush stdout
          matched <- readIORef matchRef
          exitWith (if matched then ExitSuccess else ExitFailure 1)
