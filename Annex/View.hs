{- metadata based branch views
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.View where

import Common.Annex
import Annex.View.ViewedFile
import Types.View
import Types.MetaData
import Annex.MetaData
import qualified Git
import qualified Git.DiffTree as DiffTree
import qualified Git.Branch
import qualified Git.LsFiles
import qualified Git.Ref
import Git.UpdateIndex
import Git.Sha
import Git.HashObject
import Git.Types
import Git.FilePath
import qualified Backend
import Annex.Index
import Annex.Link
import Annex.CatFile
import Logs.MetaData
import Logs.View
import Utility.Glob
import Utility.FileMode
import Types.Command
import Config
import CmdLine.Action

import qualified Data.Set as S
import qualified Data.Map as M
import "mtl" Control.Monad.Writer

{- Each visible ViewFilter in a view results in another level of
 - subdirectory nesting. When a file matches multiple ways, it will appear
 - in multiple subdirectories. This means there is a bit of an exponential
 - blowup with a single file appearing in a crazy number of places!
 -
 - Capping the view size to 5 is reasonable; why wants to dig
 - through 5+ levels of subdirectories to find anything?
 -}
viewTooLarge :: View -> Bool
viewTooLarge view = visibleViewSize view > 5

visibleViewSize :: View -> Int
visibleViewSize = length . filter viewVisible . viewComponents

{- Parses field=value, field!=value, tag, and !tag
 -
 - Note that the field may not be a legal metadata field name,
 - but it's let through anyway.
 - This is useful when matching on directory names with spaces,
 - which are not legal MetaFields.
 -}
parseViewParam :: String -> (MetaField, ViewFilter)
parseViewParam s = case separate (== '=') s of
	('!':tag, []) | not (null tag) ->
		( tagMetaField
		, mkExcludeValues tag
		)
	(tag, []) ->
		( tagMetaField
		, mkFilterValues tag
		)
	(field, wanted)
		| end field == "!" ->
			( mkMetaFieldUnchecked (beginning field)
			, mkExcludeValues wanted
			)
		| otherwise ->
			( mkMetaFieldUnchecked field
			, mkFilterValues wanted
			)
  where
	mkFilterValues v
		| any (`elem` v) "*?" = FilterGlob v
		| otherwise = FilterValues $ S.singleton $ toMetaValue v
	mkExcludeValues = ExcludeValues . S.singleton . toMetaValue

data ViewChange = Unchanged | Narrowing | Widening
	deriving (Ord, Eq, Show)

{- Updates a view, adding new fields to filter on (Narrowing), 
 - or allowing new values in an existing field (Widening). -}
refineView :: View -> [(MetaField, ViewFilter)] -> (View, ViewChange)
refineView origview = checksize . calc Unchanged origview
  where
	calc c v [] = (v, c)
	calc c v ((f, vf):rest) =
		let (v', c') = refine v f vf
		in calc (max c c') v' rest

	refine view field vf
		| field `elem` map viewField (viewComponents view) =
			let (components', viewchanges) = runWriter $
				mapM (\c -> updateViewComponent c field vf) (viewComponents view)
			    viewchange = if field `elem` map viewField (viewComponents origview)
			    	then maximum viewchanges
				else Narrowing
			in (view { viewComponents = components' }, viewchange)
		| otherwise = 
			let component = mkViewComponent field vf
			    view' = view { viewComponents = component : viewComponents view }
			in (view', Narrowing)
	
	checksize r@(v, _)
		| viewTooLarge v = error $ "View is too large (" ++ show (visibleViewSize v) ++ " levels of subdirectories)"
		| otherwise = r

updateViewComponent :: ViewComponent -> MetaField -> ViewFilter -> Writer [ViewChange] ViewComponent
updateViewComponent c field vf
	| viewField c == field = do
		let (newvf, viewchange) = combineViewFilter (viewFilter c) vf
		tell [viewchange]
		return $ mkViewComponent field newvf
	| otherwise = return c

{- Adds an additional filter to a view. This can only result in narrowing
 - the view. Multivalued filters are added in non-visible form. -}
filterView :: View -> [(MetaField, ViewFilter)] -> View
filterView v vs = v { viewComponents = viewComponents f' ++ viewComponents v}
  where
	f = fst $ refineView (v {viewComponents = []}) vs
	f' = f { viewComponents = map toinvisible (viewComponents f) }
	toinvisible c = c { viewVisible = False }

{- Combine old and new ViewFilters, yielding a result that matches
 - either old+new, or only new.
 -
 - If we have FilterValues and change to a FilterGlob,
 - it's always a widening change, because the glob could match other
 - values. OTOH, going the other way, it's a Narrowing change if the old
 - glob matches all the new FilterValues.
 -
 - With two globs, the old one is discarded, and the new one is used.
 - We can tell if that's a narrowing change by checking if the old
 - glob matches the new glob. For example, "*" matches "foo*",
 - so that's narrowing. While "f?o" does not match "f??", so that's
 - widening.
 -}
combineViewFilter :: ViewFilter -> ViewFilter -> (ViewFilter, ViewChange)
combineViewFilter old@(FilterValues olds) (FilterValues news)
	| combined == old = (combined, Unchanged)
	| otherwise = (combined, Widening)
  where
	combined = FilterValues (S.union olds news)
combineViewFilter old@(ExcludeValues olds) (ExcludeValues news)
	| combined == old = (combined, Unchanged)
	| otherwise = (combined, Narrowing)
  where
	combined = ExcludeValues (S.union olds news)
combineViewFilter (FilterValues _) newglob@(FilterGlob _) =
	(newglob, Widening)
combineViewFilter (FilterGlob oldglob) new@(FilterValues s)
	| all (matchGlob (compileGlob oldglob CaseInsensative) . fromMetaValue) (S.toList s) = (new, Narrowing)
	| otherwise = (new, Widening)
combineViewFilter (FilterGlob old) newglob@(FilterGlob new)
	| old == new = (newglob, Unchanged)
	| matchGlob (compileGlob old CaseInsensative) new = (newglob, Narrowing)
	| otherwise = (newglob, Widening)
combineViewFilter (FilterGlob _) new@(ExcludeValues _) = (new, Narrowing)
combineViewFilter (ExcludeValues _) new@(FilterGlob _) = (new, Widening)
combineViewFilter (FilterValues _) new@(ExcludeValues _) = (new, Narrowing)
combineViewFilter (ExcludeValues _) new@(FilterValues _) = (new, Widening)

{- Generates views for a file from a branch, based on its metadata
 - and the filename used in the branch.
 -
 - Note that a file may appear multiple times in a view, when it
 - has multiple matching values for a MetaField used in the View.
 -
 - Of course if its MetaData does not match the View, it won't appear at
 - all.
 -
 - Note that for efficiency, it's useful to partially
 - evaluate this function with the view parameter and reuse
 - the result. The globs in the view will then be compiled and memoized.
 -}
viewedFiles :: View -> MkViewedFile -> FilePath -> MetaData -> [ViewedFile]
viewedFiles view = 
	let matchers = map viewComponentMatcher (viewComponents view)
	in \mkviewedfile file metadata ->
		let matches = map (\m -> m metadata) matchers
		in if any isNothing matches
			then []
			else 
				let paths = pathProduct $
					map (map toViewPath) (visible matches)
				in if null paths
					then [mkviewedfile file]
					else map (</> mkviewedfile file) paths
  where
	visible = map (fromJust . snd) .
		filter (viewVisible . fst) .
		zip (viewComponents view)

{- Checks if metadata matches a ViewComponent filter, and if so
 - returns the value, or values that match. Self-memoizing on ViewComponent. -}
viewComponentMatcher :: ViewComponent -> (MetaData -> Maybe [MetaValue])
viewComponentMatcher viewcomponent = \metadata -> 
	matcher (currentMetaDataValues metafield metadata)
  where
  	metafield = viewField viewcomponent
	matcher = case viewFilter viewcomponent of
		FilterValues s -> \values -> setmatches $
			S.intersection s values
		FilterGlob glob ->
			let cglob = compileGlob glob CaseInsensative
			in \values -> setmatches $
				S.filter (matchGlob cglob . fromMetaValue) values
		ExcludeValues excludes -> \values -> 
			if S.null (S.intersection values excludes)
				then Just []
				else Nothing
	setmatches s
		| S.null s = Nothing
		| otherwise = Just (S.toList s)

toViewPath :: MetaValue -> FilePath
toViewPath = concatMap escapeslash . fromMetaValue
  where
	escapeslash c
		| c == '/' = [pseudoSlash]
		| c == '\\' = [pseudoBackslash]
		| c == pseudoSlash = [pseudoSlash, pseudoSlash]
		| c == pseudoBackslash = [pseudoBackslash, pseudoBackslash]
		| otherwise = [c]

fromViewPath :: FilePath -> MetaValue
fromViewPath = toMetaValue . deescapeslash []
  where
  	deescapeslash s [] = reverse s
  	deescapeslash s (c:cs)
		| c == pseudoSlash = case cs of
			(c':cs')
				| c' == pseudoSlash -> deescapeslash (pseudoSlash:s) cs'
			_ -> deescapeslash ('/':s) cs
		| c == pseudoBackslash = case cs of
			(c':cs')
				| c' == pseudoBackslash -> deescapeslash (pseudoBackslash:s) cs'
			_ -> deescapeslash ('/':s) cs
		| otherwise = deescapeslash (c:s) cs

pseudoSlash :: Char
pseudoSlash = '\8725' -- '∕' /= '/'

pseudoBackslash :: Char
pseudoBackslash = '\9586' -- '╲' /= '\'

pathProduct :: [[FilePath]] -> [FilePath]
pathProduct [] = []
pathProduct (l:ls) = foldl combinel l ls
  where
	combinel xs ys = [combine x y | x <- xs, y <- ys]

{- Extracts the metadata from a ViewedFile, based on the view that was used
 - to construct it.
 -
 - Derived metadata is excluded.
 -}
fromView :: View -> ViewedFile -> MetaData
fromView view f = MetaData $
	M.fromList (zip fields values) `M.difference` derived
  where
	visible = filter viewVisible (viewComponents view)
	fields = map viewField visible
	paths = splitDirectories (dropFileName f)
	values = map (S.singleton . fromViewPath) paths
	MetaData derived = getViewedFileMetaData f

{- Constructing a view that will match arbitrary metadata, and applying
 - it to a file yields a set of ViewedFile which all contain the same
 - MetaFields that were present in the input metadata
 - (excluding fields that are not visible). -}
prop_view_roundtrips :: FilePath -> MetaData -> Bool -> Bool
prop_view_roundtrips f metadata visible = null f || viewTooLarge view ||
	all hasfields (viewedFiles view viewedFileFromReference f metadata)
  where
	view = View (Git.Ref "master") $
		map (\(mf, mv) -> ViewComponent mf (FilterValues $ S.filter (not . null . fromMetaValue) mv) visible)
			(fromMetaData metadata)
	visiblefields = sort (map viewField $ filter viewVisible (viewComponents view))
	hasfields fv = sort (map fst (fromMetaData (fromView view fv))) == visiblefields

{- A directory foo/bar/baz/ is turned into metadata fields
 - /=foo, foo/=bar, foo/bar/=baz.
 -
 - Note that this may generate MetaFields that legalField rejects.
 - This is necessary to have a 1:1 mapping between directory names and
 - fields. So this MetaData cannot safely be serialized. -}
getDirMetaData :: FilePath -> MetaData
getDirMetaData d = MetaData $ M.fromList $ zip fields values
  where
	dirs = splitDirectories d
	fields = map (mkMetaFieldUnchecked . addTrailingPathSeparator . joinPath)
		(inits dirs)
	values = map (S.singleton . toMetaValue . fromMaybe "" . headMaybe)
		(tails dirs)

getWorkTreeMetaData :: FilePath -> MetaData
getWorkTreeMetaData = getDirMetaData . dropFileName

getViewedFileMetaData :: FilePath -> MetaData
getViewedFileMetaData = getDirMetaData . dirFromViewedFile . takeFileName

{- Applies a view to the currently checked out branch, generating a new
 - branch for the view.
 -}
applyView :: View -> Annex Git.Branch
applyView view = applyView' viewedFileFromReference getWorkTreeMetaData view

{- Generates a new branch for a View, which must be a more narrow
 - version of the View originally used to generate the currently
 - checked out branch. That is, it must match a subset of the files
 - in view, not any others.
 -}
narrowView :: View -> Annex Git.Branch
narrowView = applyView' viewedFileReuse getViewedFileMetaData

{- Go through each file in the currently checked out branch.
 - If the file is not annexed, skip it, unless it's a dotfile in the top.
 - Look up the metadata of annexed files, and generate any ViewedFiles,
 - and stage them.
 -
 - Currently only works in indirect mode. Must be run from top of
 - repository.
 -}
applyView' :: MkViewedFile -> (FilePath -> MetaData) -> View -> Annex Git.Branch
applyView' mkviewedfile getfilemetadata view = do
	top <- fromRepo Git.repoPath
	(l, clean) <- inRepo $ Git.LsFiles.inRepo [top]
	liftIO . nukeFile =<< fromRepo gitAnnexViewIndex
	genViewBranch view $ do
		uh <- inRepo Git.UpdateIndex.startUpdateIndex
		hasher <- inRepo hashObjectStart
		forM_ l $ \f ->
			go uh hasher f =<< Backend.lookupFile f
		liftIO $ do
			hashObjectStop hasher
			void $ stopUpdateIndex uh
			void clean
  where
	genviewedfiles = viewedFiles view mkviewedfile -- enables memoization
	go uh hasher f (Just (k, _)) = do
		metadata <- getCurrentMetaData k
		let metadata' = getfilemetadata f `unionMetaData` metadata
		forM_ (genviewedfiles f metadata') $ \fv -> do
			stagesymlink uh hasher fv =<< inRepo (gitAnnexLink fv k)
	go uh hasher f Nothing
		| "." `isPrefixOf` f = do
			s <- liftIO $ getSymbolicLinkStatus f
			if isSymbolicLink s
				then stagesymlink uh hasher f =<< liftIO (readSymbolicLink f)
				else do
					sha <- liftIO $ Git.HashObject.hashFile hasher f
					let blobtype = if isExecutable (fileMode s)
						then ExecutableBlob
						else FileBlob
					liftIO . Git.UpdateIndex.streamUpdateIndex' uh
						=<< inRepo (Git.UpdateIndex.stageFile sha blobtype f)
		| otherwise = noop
	stagesymlink uh hasher f linktarget = do
		sha <- hashSymlink' hasher linktarget
		liftIO . Git.UpdateIndex.streamUpdateIndex' uh
			=<< inRepo (Git.UpdateIndex.stageSymlink f sha)

{- Applies a view to the reference branch, generating a new branch
 - for the View.
 -
 - This needs to work incrementally, to quickly update the view branch
 - when the reference branch is changed. So, it works based on an
 - old version of the reference branch, uses diffTree to find the
 - changes, and applies those changes to the view branch.
 -}
updateView :: View -> Git.Ref -> Git.Ref -> Annex Git.Branch
updateView view ref oldref = genViewBranch view $ do
	(diffs, cleanup) <- inRepo $ DiffTree.diffTree oldref ref
	forM_ diffs go
	void $ liftIO cleanup
  where
	go diff
		| DiffTree.dstsha diff == nullSha = error "TODO delete file"
		| otherwise = error "TODO add file"

{- Diff between currently checked out branch and staged changes, and
 - update metadata to reflect the changes that are being committed to the
 - view.
 -
 - Adding a file to a directory adds the metadata represented by
 - that directory to the file, and removing a file from a directory
 - removes the metadata.
 -
 - Note that removes must be handled before adds. This is so
 - that moving a file from x/foo/ to x/bar/ adds back the metadata for x.
 -}
withViewChanges :: (ViewedFile -> Key -> CommandStart) -> (ViewedFile -> Key -> CommandStart) -> Annex ()
withViewChanges addmeta removemeta = do
	makeabs <- flip fromTopFilePath <$> gitRepo
	(diffs, cleanup) <- inRepo $ DiffTree.diffIndex Git.Ref.headRef
	forM_ diffs handleremovals
	forM_ diffs (handleadds makeabs)
	void $ liftIO cleanup
  where
	handleremovals item
		| DiffTree.srcsha item /= nullSha =
			handle item removemeta
				=<< catKey (DiffTree.srcsha item) (DiffTree.srcmode item)
		| otherwise = noop
	handleadds makeabs item
		| DiffTree.dstsha item /= nullSha = 
			handle item addmeta
				=<< ifM isDirect
					( catKey (DiffTree.dstsha item) (DiffTree.dstmode item)
					-- optimisation
					, isAnnexLink $ makeabs $ DiffTree.file item
					)
		| otherwise = noop
	handle item a = maybe noop
		(void . commandAction . a (getTopFilePath $ DiffTree.file item))

{- Generates a branch for a view. This is done using a different index
 - file. An action is run to stage the files that will be in the branch.
 - Then a commit is made, to the view branch. The view branch is not
 - checked out, but entering it will display the view. -}
genViewBranch :: View -> Annex () -> Annex Git.Branch
genViewBranch view a = withIndex $ do
	a
	let branch = branchView view
	void $ inRepo $ Git.Branch.commit True (fromRef branch) branch []
	return branch

{- Runs an action using the view index file.
 - Note that the file does not necessarily exist, or can contain
 - info staged for an old view. -}
withIndex :: Annex a -> Annex a
withIndex a = do
	f <- fromRepo gitAnnexViewIndex
	withIndexFile f a

withCurrentView :: (View -> Annex a) -> Annex a
withCurrentView a = maybe (error "Not in a view.") a =<< currentView
