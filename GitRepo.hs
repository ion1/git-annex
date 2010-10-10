{- git repository handling -}

module GitRepo where

import Directory
import System.Directory
import System.Path
import Data.String.Utils
import Utility
import Types

{- GitRepo constructor -}
gitRepo :: FilePath -> IO GitRepo
gitRepo dir = do
	-- TOOD query repo for configuration settings; other repositories; etc
	return GitRepo {
		top = dir,
		remotes = []
	}

{- Path to a repository's gitattributes file. -}
gitAttributes :: GitRepo -> IO String
gitAttributes repo = do
	bare <- isBareRepo (top repo)
	if (bare)
		then return $ (top repo) ++ "/info/.gitattributes"
		else return $ (top repo) ++ "/.gitattributes"

{- Path to a repository's .git directory.
 - (For a bare repository, that is the root of the repository.)
 - TODO: support GIT_DIR -}
gitDir :: GitRepo -> IO String
gitDir repo = do
	bare <- isBareRepo (top repo)
	if (bare)
		then return $ (top repo)
		else return $ (top repo) ++ "/.git"

{- Given a relative or absolute filename, calculates the name to use
 - to refer to the file relative to a git repository directory.
 - This is the same form displayed and used by git. -}
gitRelative :: GitRepo -> String -> String
gitRelative repo file = drop (length absrepo) absfile
	where
		-- normalize both repo and file, so that repo
		-- will be substring of file
		absrepo = case (absNormPath "/" (top repo)) of
			Just f -> f ++ "/"
			Nothing -> error $ "bad repo" ++ (top repo)
		absfile = case (secureAbsNormPath absrepo file) of
			Just f -> f
			Nothing -> error $ file ++ " is not located inside git repository " ++ absrepo

{- Stages a changed file in git's index. -}
gitAdd repo file = do
	-- TODO
	return ()

{- Finds the current git repository, which may be in a parent directory. -}
currentRepo :: IO GitRepo
currentRepo = do
	cwd <- getCurrentDirectory
	top <- seekUp cwd isRepoTop
	case top of
		(Just dir) -> gitRepo dir
		Nothing -> error "Not in a git repository."

seekUp :: String -> (String -> IO Bool) -> IO (Maybe String)
seekUp dir want = do
	ok <- want dir
	if ok
		then return (Just dir)
		else case (parentDir dir) of
			"" -> return Nothing
			d -> seekUp d want

isRepoTop dir = do
	r <- isGitRepo dir
	b <- isBareRepo dir
	return (r || b)

isGitRepo dir = gitSignature dir ".git" ".git/config"
isBareRepo dir = gitSignature dir "objects" "config"
	
gitSignature dir subdir file = do
	s <- (doesDirectoryExist (dir ++ "/" ++ subdir))
	f <- (doesFileExist (dir ++ "/" ++ file))
	return (s && f)
