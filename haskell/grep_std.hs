-- haskgrep_std - idiomatic single-threaded Haskell.
-- Strict Data.ByteString (Word8 octets) all the way: byte-exact offsets,
-- breakSubstring for the literal search, System.Directory for the walk.
-- No threads, no hand-rolled SIMD/syscalls. stdlib only.
module Main (main) where

import qualified Data.ByteString as BS
import           Data.ByteString (ByteString)
import           Data.Word (Word8)
import           Data.IORef
import           System.Environment (getArgs)
import           System.Exit (exitWith, ExitCode (..))
import           System.IO
import           System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import           System.FilePath ((</>))
import qualified Data.ByteString.Char8 as BC

-- Config carried explicitly (single-threaded, but keep it pure-ish).
data Cfg = Cfg
  { cfgPat    :: !ByteString   -- needle as given
  , cfgLPat   :: !ByteString   -- ASCII-lowercased needle (for -i)
  , cfgCI     :: !Bool
  , cfgMulti  :: !Bool
  , cfgMatch  :: !(IORef Bool)
  }

-- ASCII-only, length-preserving lowercase. Matches grep -iF; NOT Unicode
-- Data.Char.toLower (which could change byte length / offsets).
asciiLower :: ByteString -> ByteString
asciiLower = BS.map (\b -> if b >= 65 && b <= 90 then b + 32 else b)

nul :: Word8
nul = 0

nl :: Word8
nl = 10

searchFile :: Cfg -> FilePath -> IO ()
searchFile cfg path = do
  dat <- BS.readFile path
  let len  = BS.length dat
      peek = min len 65536
  if BS.elem nul (BS.take peek dat)
    then return ()                       -- binary, skip
    else do
      let (hay, needle)
            | cfgCI cfg = (asciiLower dat, cfgLPat cfg)
            | otherwise = (dat, cfgPat cfg)
          loop pos
            | pos >= len = return ()      -- pos < len guard: empty-pattern fix
            | otherwise =
                let (pre, post) = BS.breakSubstring needle (BS.drop pos hay)
                in if BS.null post && not (BS.null needle)
                     then return ()       -- not found
                     else if BS.null post
                            then return () -- empty needle, no occurrence past pos
                            else do
                              let m  = pos + BS.length pre
                                  ls = lastNlBefore dat m + 1
                                  le = firstNlAt dat m len
                              writeIORef (cfgMatch cfg) True
                              if cfgMulti cfg
                                then BS.hPutStr stdout (BC.pack path) >> BS.hPutStr stdout (BS.singleton 58)
                                else return ()
                              BS.hPutStr stdout (BS.take (le - ls) (BS.drop ls dat))
                              BS.hPutStr stdout (BS.singleton nl)
                              loop (le + 1)
      loop 0

-- last index of '\n' strictly before m, or -1.
lastNlBefore :: ByteString -> Int -> Int
lastNlBefore dat m =
  case BS.elemIndexEnd nl (BS.take m dat) of
    Just i  -> i
    Nothing -> -1

-- first index of '\n' at/after m, or `len`.
firstNlAt :: ByteString -> Int -> Int -> Int
firstNlAt dat m len =
  case BS.elemIndex nl (BS.drop m dat) of
    Just j  -> m + j
    Nothing -> len

-- Recursive walk: regular files only, never follow symlinks.
walk :: Cfg -> FilePath -> IO ()
walk cfg p = do
  isLink <- pathIsSymbolicLink p
  if isLink
    then return ()
    else do
      isDir <- doesDirectoryExist p
      if isDir
        then do
          entries <- listDirectory p
          mapM_ (\e -> walk cfg (p </> e)) entries
        else searchFile cfg p

usage :: IO a
usage = do
  hPutStr stderr "usage: haskgrep [-r] [-i] PATTERN PATH...\n"
  exitWith (ExitFailure 2)

-- Parse args: flags may combine (-ri); -- ends options; first non-flag = PATTERN.
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
            Nothing          -> Nothing      -- unknown flag
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
      matchRef <- newIORef False
      let multi = recursive || length paths > 1
          cfg = Cfg { cfgPat = pat
                    , cfgLPat = asciiLower pat
                    , cfgCI = ci
                    , cfgMulti = multi
                    , cfgMatch = matchRef
                    }
      mapM_ (processPath cfg recursive) paths
      hFlush stdout
      matched <- readIORef matchRef
      exitWith (if matched then ExitSuccess else ExitFailure 1)

processPath :: Cfg -> Bool -> FilePath -> IO ()
processPath cfg recursive p = do
  isDir <- doesDirectoryExist p
  if isDir
    then if recursive then walk cfg p else return ()   -- dir w/o -r: skip
    else searchFile cfg p
