{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Org.Lint where

import Control.Applicative
import Control.Lens
import Control.Monad (foldM, unless, when)
import Control.Monad.Writer
import Data.Data
import Data.Foldable (forM_)
import Data.Hashable
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Debug.Trace (traceM)
import GHC.Generics hiding (to)
import Org.Data
import Org.Printer
import Org.Types
import Text.Megaparsec (parseMaybe)
import Text.Megaparsec.Char (string)
import Text.Show.Pretty

data LintMessageKind = LintDebug | LintInfo | LintWarn | LintError
  deriving (Show, Eq, Ord, Generic, Data, Typeable, Hashable)

parseLintMessageKind :: BasicParser LintMessageKind
parseLintMessageKind =
  (LintError <$ string "ERROR")
    <|> (LintWarn <$ string "WARN")
    <|> (LintInfo <$ string "INFO")
    <|> (LintDebug <$ string "DEBUG")

data LintMessageCode
  = TodoMissingProperty Text Entry
  | MisplacedProperty Entry
  | MisplacedTimestamp Entry
  | MisplacedLogEntry Entry
  | MisplacedDrawerEnd Entry
  | DuplicateFileProperty Text OrgFile
  | DuplicateProperty Text Entry
  | DuplicateTag Text Entry
  | DuplicatedIdentifier Text (NonEmpty Entry)
  | InvalidStateChangeTransitionNotAllowed Text (Maybe Text) [Text] Entry
  | InvalidStateChangeInvalidTransition Text Text Entry
  | InvalidStateChangeWrongTimeOrder Time Time Entry
  | InvalidStateChangeIdempotent Text Entry
  | MultipleLogbooks Entry
  | MixedLogbooks Entry
  | TitleWithExcessiveWhitespace Entry
  | TimestampsOnNonTodo Entry
  | UnevenBodyWhitespace Entry
  | UnevenFilePreambleWhitespace OrgFile
  | EmptyBodyWhitespace Entry
  | MultipleBlankLines Entry
  | CategoryTooLong Text Entry
  deriving (Show, Eq, Generic, Data, Typeable, Hashable)

data LintMessage = LintMessage
  { lintMsgKind :: LintMessageKind,
    lintMsgCode :: LintMessageCode
  }
  deriving (Show, Eq, Generic, Data, Typeable, Hashable)

lintOrgData :: Config -> String -> OrgData -> [LintMessage]
lintOrgData cfg level org = snd . runWriter $ do
  let ids = foldAllEntries org M.empty $ \e m ->
        maybe
          m
          ( \ident ->
              m
                & at ident %~ Just . maybe (NE.singleton e) (NE.cons e)
          )
          (e ^? entryId)

  forM_ (M.assocs ids) $ \(k, es) ->
    when (NE.length es > 1) $
      tell [LintMessage LintError (DuplicatedIdentifier k es)]

  let level' =
        fromMaybe
          LintInfo
          (parseMaybe parseLintMessageKind (T.pack level))

  mapM_ (lintOrgFile cfg level') (org ^. orgFiles)

lintOrgFile :: Config -> LintMessageKind -> OrgFile -> Writer [LintMessage] ()
lintOrgFile cfg level org = do
  -- jww (2024-05-28): RULE: filenames with dates should have matching CREATED
  -- property
  forM_ (findDuplicates (props ^.. traverse . name)) $ \nm ->
    report LintError (DuplicateFileProperty nm org)
  -- checkFor LintInfo (UnevenFilePreambleWhitespace org) $
  --   org ^? fileHeader . headerPreamble . leadSpace
  --     /= org ^? fileHeader . headerPreamble . endSpace
  case reverse (org ^.. allEntries) of
    [] -> pure ()
    e : es -> do
      mapM_ (lintOrgEntry cfg False level) (reverse es)
      lintOrgEntry cfg True level e
  where
    props =
      org ^. fileHeader . headerPropertiesDrawer
        ++ org ^. fileHeader . headerFileProperties

    report kind code
      | kind >= level = do
          when (level == LintDebug) $
            traceM $
              "file: " ++ ppShow org
          tell [LintMessage kind code]
      | otherwise = pure ()

lintOrgEntry ::
  Config ->
  Bool ->
  LintMessageKind ->
  Entry ->
  Writer [LintMessage] ()
lintOrgEntry cfg lastEntry level e = do
  -- RULE: All TODO entries have ID and CREATED properties
  let mkw = e ^? entryKeyword . _Just . keywordText
  when (isJust mkw || isJust (e ^? entryCategory)) $ do
    when (isNothing (e ^? entryId)) $
      report LintError (TodoMissingProperty "ID" e)
    when (isNothing (e ^? entryCreated)) $
      report LintError (TodoMissingProperty "CREATED" e)
  forM_ (e ^? entryCategory) $ \cat ->
    when (T.length cat > 10) $
      report LintWarn (CategoryTooLong cat e)
  -- jww (2024-05-28): RULE: Only TODO items have SCHEDULED/DEADLINE/CLOSED
  --   timestamps
  -- jww (2024-05-27): RULE: No open keywords in archives
  -- jww (2024-05-28): RULE: No CREATED date lies in the future
  -- jww (2024-05-28): RULE: No title has special characters without escaping

  -- jww (2024-05-28): RULE: Leading and trailing whitespace is consistent
  --   within log entries

  -- jww (2024-05-28): RULE: There is no whitespace preceding the event log

  -- jww (2024-05-28): RULE: There is no whitespace after the PROPERTY block
  --   (and/or event log) when there is no whitespace at the end of the entry

  -- jww (2024-05-28): RULE: If an entry has trailing whitespace, it's
  --   siblings have the same whitespace

  -- jww (2024-05-28): RULE: Property blocks are never empty

  -- jww (2024-05-28): RULE: Don't use :SCRIPT:, use org-babel

  when
    ( any
        ((":properties:" `T.isInfixOf`) . T.toLower)
        (bodyText (has _Paragraph))
    )
    $ report LintError (MisplacedProperty e)
  when
    ( any
        ( \t ->
            "SCHEDULED:" `T.isInfixOf` t
              || "DEADLINE:" `T.isInfixOf` t
              || "CLOSED:" `T.isInfixOf` t
        )
        (bodyText (has _Paragraph))
    )
    $ report LintError (MisplacedTimestamp e)
  when
    ( any
        ( \t ->
            "- CLOSING NOTE " `T.isInfixOf` t
              || "- State " `T.isInfixOf` t
              || "- Note taken on " `T.isInfixOf` t
              || "- Rescheduled from " `T.isInfixOf` t
              || "- Not scheduled, was " `T.isInfixOf` t
              || "- New deadline from " `T.isInfixOf` t
              || "- Removed deadline, was " `T.isInfixOf` t
              || "- Refiled on " `T.isInfixOf` t
              || ":logbook:" `T.isInfixOf` T.toLower t
        )
        (bodyText (has _Paragraph))
    )
    $ report LintError (MisplacedLogEntry e)
  when
    ( any
        ( ( \t ->
              ":end:" `T.isInfixOf` t
                || "#+end" `T.isInfixOf` t
          )
            . T.toLower
        )
        (bodyText (has _Paragraph))
    )
    $ report LintError (MisplacedDrawerEnd e)
  -- RULE: No title has internal whitespace other than single spaces.
  when ("  " `T.isInfixOf` (e ^. entryTitle)) $
    report LintInfo (TitleWithExcessiveWhitespace e)
  -- RULE: No tag is duplicated.
  forM_ (findDuplicates (e ^.. entryTags . traverse . tagText)) $ \nm ->
    report LintError (DuplicateTag nm e)
  -- RULE: No property is duplicated
  forM_ (findDuplicates (e ^.. entryProperties . traverse . name)) $ \nm ->
    report LintError (DuplicateProperty nm e)
  (mfinalKeyword, _mfinalTime) <-
    ( \f ->
        foldM
          f
          ( Nothing,
            Nothing
          )
          -- jww (2024-05-28): Only reverse here if the configuration indicates
          -- that state entries are from most recent to least recent.
          (reverse (e ^.. entryStateHistory))
      )
      $ \(mprev, mprevTm) (kw', mkw', tm) -> do
        forM_ mprevTm $ \prevTm ->
          when (tm < prevTm) $
            report LintWarn (InvalidStateChangeWrongTimeOrder tm prevTm e)
        let kwt = kw' ^. keywordText
            mkwf = fmap (^. keywordText) mkw'
            mallowed = transitionsOf cfg <$> mkwf
        forM_ mkwf $ \kwf ->
          case mprev of
            Nothing ->
              unless (kwf `elem` ["TODO", "APPT", "PROJECT"]) $
                report
                  LintInfo
                  (InvalidStateChangeInvalidTransition kwf "TODO" e)
            Just prev ->
              unless (prev == kwf) $
                report
                  LintInfo
                  (InvalidStateChangeInvalidTransition kwf prev e)
        if mkwf == Just kwt
          then report LintWarn (InvalidStateChangeIdempotent kwt e)
          else forM_ mallowed $ \allowed ->
            unless (kwt `elem` allowed) $
              report
                LintWarn
                (InvalidStateChangeTransitionNotAllowed kwt mkwf allowed e)
        pure (Just kwt, Just tm)
  forM_ ((,) <$> mkw <*> mfinalKeyword) $ \(kw, finalKeyword) ->
    unless (kw == finalKeyword) $
      report
        LintInfo
        (InvalidStateChangeInvalidTransition kw finalKeyword e)
  when
    ( not (null (e ^. entryStamps))
        && maybe True (not . isTodo) (e ^? keyword)
    )
    $ report LintWarn (TimestampsOnNonTodo e)
  when
    ( not lastEntry && case e ^. entryText of
        Body [Whitespace _] -> False
        _ -> e ^? entryText . leadSpace /= e ^? entryText . endSpace
    )
    $ report LintInfo (UnevenBodyWhitespace e)
  forM_ (e ^.. entryLogEntries . traverse . cosmos . _LogBody) $ \b ->
    when
      ( case b of
          Body [Whitespace _] -> maybe False isTodo (e ^? keyword)
          _ -> False
      )
      $ report LintInfo (EmptyBodyWhitespace e)
  when
    ( case e ^. entryText of
        Body [Whitespace _] -> maybe False isTodo (e ^? keyword)
        _ -> False
    )
    $ report LintInfo (EmptyBodyWhitespace e)
  when (any ((> 1) . length . T.lines) (bodyText (has _Whitespace))) $
    report LintInfo (MultipleBlankLines e)
  when (length (e ^.. entryLogEntries . traverse . cosmos . _LogBook) > 1) $
    report LintError (MultipleLogbooks e)
  when
    ( not
        ( null
            ( e
                ^.. entryLogEntries
                  . traverse
                  . _LogBook
                  . traverse
                  . filtered (hasn't _LogClock)
            )
        )
        && not
          ( null
              ( e
                  ^.. entryLogEntries
                    . traverse
                    . filtered (hasn't _LogBook)
              )
          )
    )
    $ report LintError (MixedLogbooks e)
  where
    bodyText f =
      e
        ^. entryText
          . blocks
          . traverse
          . filtered f
          . to (showBlock "")
        ++ e
          ^. entryLogEntries
            . traverse
            . failing (_LogState . _4) (_LogNote . _2)
            . _Just
            . blocks
            . traverse
            . filtered f
            . to (showBlock "")

    report kind code
      | kind >= level = do
          when (level == LintDebug) $
            traceM $
              "entry: " ++ ppShow e
          tell [LintMessage kind code]
      | otherwise = pure ()

showLintOrg :: LintMessage -> String
showLintOrg (LintMessage kind code) =
  renderCode
  where
    entryLoc e =
      e ^. entryFile
        ++ ":"
        ++ show (e ^. entryLine)
        ++ ":"
        ++ show (e ^. entryColumn)
    renderKind = case kind of
      LintError -> "ERROR"
      LintWarn -> "WARN"
      LintInfo -> "INFO"
      LintDebug -> "DEBUG"
    prefix e =
      entryLoc e
        ++ ": "
        ++ renderKind
        ++ " "
    renderCode = case code of
      TodoMissingProperty nm e ->
        prefix e ++ "Open todo missing property " ++ show nm
      MisplacedProperty e ->
        prefix e ++ "Misplaced :PROPERTIES: block"
      MisplacedTimestamp e ->
        prefix e ++ "Misplaced timestamp (SCHEDULED, DEADLINE or CLOSED)"
      MisplacedLogEntry e ->
        prefix e ++ "Misplaced state change, note or LOGBOOK"
      MisplacedDrawerEnd e ->
        prefix e ++ "Misplaced end of drawer"
      TitleWithExcessiveWhitespace e ->
        prefix e ++ "Title with excessive whitespace"
      DuplicateFileProperty nm f ->
        f ^. filePath ++ ":1: " ++ "Duplicated file property " ++ show nm
      DuplicateProperty nm e ->
        prefix e ++ "Duplicated property " ++ show nm
      DuplicateTag nm e ->
        prefix e ++ "Duplicated tag " ++ show nm
      DuplicatedIdentifier ident (e :| es) ->
        prefix e
          ++ "Duplicated identifier "
          ++ T.unpack ident
          ++ "\n"
          ++ intercalate "\n" (map (("  " ++) . entryLoc) es)
      InvalidStateChangeTransitionNotAllowed kwt mkwf allowed e ->
        prefix e
          ++ "Transition not allowed "
          ++ show mkwf
          ++ " -> "
          ++ show kwt
          ++ ", allowed: "
          ++ show allowed
      InvalidStateChangeInvalidTransition kwt kwf e ->
        prefix e
          ++ "Invalid state transition "
          ++ show kwf
          ++ " -> "
          ++ show kwt
      InvalidStateChangeWrongTimeOrder after before e ->
        prefix e
          ++ "Wrong time order in state transition "
          ++ show (showTime before)
          ++ " > "
          ++ show (showTime after)
      InvalidStateChangeIdempotent kw e ->
        prefix e ++ "Idempotent state transition " ++ show kw
      MultipleLogbooks e ->
        prefix e ++ "Multiple logbooks found"
      MixedLogbooks e ->
        prefix e ++ "Log entries inside and outside of logbooks found"
      TimestampsOnNonTodo e ->
        prefix e ++ "Timestamps found on non-todo entry"
      UnevenBodyWhitespace e ->
        prefix e ++ "Whitespace surrounding body is not even"
      UnevenFilePreambleWhitespace f ->
        f ^. filePath
          ++ ":1: "
          ++ "Whitespace surrounding file preamble is not even"
      EmptyBodyWhitespace e ->
        prefix e ++ "Whitespace only body"
      MultipleBlankLines e ->
        prefix e ++ "Multiple blank lines"
      CategoryTooLong cat e ->
        prefix e ++ "Category name is too long: " ++ show cat
