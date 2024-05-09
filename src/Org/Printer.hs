{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Org.Printer where

import Data.Maybe (maybeToList)
import Data.Text.Lazy (Text, pack)
import Data.Text.Lazy qualified as T
import Data.Time
import Org.Types hiding (propertyColumn, tagsColumn)

showStamp :: Stamp -> Text
showStamp (ClosedStamp tm) = "CLOSED: " <> showTime tm
showStamp (ScheduledStamp tm) = "SCHEDULED: " <> showTime tm
showStamp (DeadlineStamp tm) = "DEADLINE: " <> showTime tm

showTime :: Time -> Text
showTime ts =
  T.concat $
    showTimeSingle ts
      : case _timeDayEnd ts of
        Nothing -> []
        Just end ->
          [ "--",
            showTimeSingle
              ts
                { _timeDay = end,
                  _timeDayEnd = Nothing,
                  _timeStart = _timeEnd ts,
                  _timeEnd = Nothing
                }
          ]
  where
    showTimeSingle :: Time -> Text
    showTimeSingle Time {..} =
      T.concat $
        [ beg,
          pack
            ( formatTime
                defaultTimeLocale
                "%Y-%m-%d %a"
                (ModifiedJulianDay _timeDay)
            )
        ]
          ++ case _timeStart of
            Nothing -> []
            Just start ->
              [ pack
                  ( formatTime
                      defaultTimeLocale
                      " %H:%M"
                      ( UTCTime
                          (ModifiedJulianDay _timeDay)
                          (secondsToDiffTime start)
                      )
                  )
              ]
          ++ case _timeEnd of
            Nothing -> []
            Just finish ->
              [ pack
                  ( formatTime
                      defaultTimeLocale
                      "-%H:%M"
                      ( UTCTime
                          (ModifiedJulianDay _timeDay)
                          (secondsToDiffTime finish)
                      )
                  )
              ]
          ++ case _timeSuffix of
            Nothing -> []
            Just TimeSuffix {..} ->
              [ " ",
                case _suffixKind of
                  TimeRepeat -> "+"
                  TimeDottedRepeat -> ".+"
                  TimeWithin -> "-",
                pack (show _suffixNum),
                case _suffixSpan of
                  DaySpan -> "d"
                  WeekSpan -> "w"
                  MonthSpan -> "m"
              ]
                ++ case _suffixLargerSpan of
                  Nothing -> []
                  Just (num, s) ->
                    [ pack (show num),
                      case s of
                        DaySpan -> "d"
                        WeekSpan -> "w"
                        MonthSpan -> "m"
                    ]
          ++ [ end
             ]
      where
        (beg, end) = case _timeKind of
          ActiveTime -> ("<", ">")
          InactiveTime -> ("[", "]")

showLogEntry :: LogEntry -> [Text]
showLogEntry (LogStateChange from to tm text) =
  T.concat
    ( [ "- State \"",
        showKeyword from
      ]
        ++ [ "\" from \"" <> showKeyword k
             | k <- maybeToList to
           ]
        ++ [ "\" ",
             showTime tm,
             if null text then "" else " \\\\"
           ]
    )
    : map ("  " <>) text
showLogEntry (LogNote tm text) =
  ( "- Note taken on "
      <> showTime tm
      <> if null text then "" else " \\\\"
  )
    : map ("  " <>) text

showKeyword :: Keyword -> Text
showKeyword (OpenKeyword n) = n
showKeyword (ClosedKeyword n) = n

showEntry :: Int -> Int -> Entry -> [Text]
showEntry propertyColumn tagsColumn Entry {..} =
  [title]
    ++ timestamps
    ++ properties
    ++ logEntries
    ++ body
    ++ concatMap (showEntry propertyColumn tagsColumn) _entryItems
  where
    title
      | T.null suffix = prefix
      | otherwise = prefix <> spacer <> suffix
      where
        spacer
          | width < 2 = "  "
          | otherwise = T.replicate (fromIntegral width) " "
          where
            width =
              tagsColumn
                - fromIntegral (T.length prefix)
                - fromIntegral (T.length suffix)
        prefix =
          T.concat $
            [T.replicate (fromIntegral _entryDepth) "*"]
              ++ [" "]
              ++ [showKeyword kw <> " " | kw <- maybeToList _entryKeyword]
              ++ [ "(" <> c <> ") "
                   | c <- maybeToList _entryContext
                 ]
              ++ [_entryTitle]
              ++ [ " {" <> c <> "}"
                   | c <- maybeToList _entryLocator
                 ]
        suffix
          | not (null _entryTags) =
              T.concat $
                ":"
                  : [ case tag of
                        SpecialTag t -> t <> ":"
                        PlainTag t -> t <> ":"
                      | tag <- _entryTags
                    ]
          | otherwise = ""
    timestamps
      | null _entryStamps = []
      | otherwise = [T.intercalate " " (map showStamp _entryStamps)]
    properties
      | null _entryProperties = []
      | otherwise = showProperties propertyColumn _entryProperties
    logEntries = concatMap showLogEntry _entryLogEntries
    body = _entryText

showOrgFile :: Int -> Int -> OrgFile -> [Text]
showOrgFile propertyColumn tagsColumn OrgFile {..} =
  showHeader propertyColumn _fileHeader
    ++ concatMap (showEntry propertyColumn tagsColumn) _fileEntries

showHeader :: Int -> Header -> [Text]
showHeader propertyColumn Header {..} =
  propertiesDrawer
    ++ fileProperties
    ++ preamble
  where
    propertiesDrawer
      | null _headerPropertiesDrawer = []
      | otherwise = showProperties propertyColumn _headerPropertiesDrawer
    fileProperties
      | null _headerFileProperties = []
      | otherwise = showFileProperties _headerFileProperties
    preamble = _headerPreamble

showProperties :: Int -> [Property] -> [Text]
showProperties propertyColumn ps =
  [":PROPERTIES:"]
    ++ map propLine ps
    ++ [":END:"]
  where
    propLine Property {..}
      | T.null suffix = prefix
      | otherwise = prefix <> spacer <> suffix
      where
        spacer
          | width < 1 = " "
          | otherwise = T.replicate (fromIntegral width) " "
          where
            width = propertyColumn - fromIntegral (T.length prefix)
        prefix = T.concat [":" <> _name <> ":"]
        suffix = _value

showFileProperties :: [Property] -> [Text]
showFileProperties ps =
  [ "#+" <> _name <> ": " <> _value
    | Property {..} <- ps
  ]

summarizeEntry :: Entry -> [Text]
summarizeEntry Entry {..} =
  [T.replicate (fromIntegral _entryDepth) "*" <> " " <> _entryTitle]
    ++ showProperties
      0
      ( _entryProperties
          ++ [Property False "FILE" (T.pack _entryFile)]
          ++ [Property False "LINE" (T.pack (show _entryLine))]
          ++ [Property False "COLUMN" (T.pack (show _entryColumn))]
          ++ [ Property False "KEYWORD" (T.pack (show x))
               | x <- maybeToList _entryKeyword
             ]
          ++ [Property False "PRIORITY" x | x <- maybeToList _entryPriority]
          ++ [Property False "CONTEXT" x | x <- maybeToList _entryContext]
          ++ [Property False "LOCATOR" x | x <- maybeToList _entryLocator]
          ++ [ Property
                 False
                 "LOG_LEN"
                 (T.pack (show (length _entryLogEntries)))
               | not (null _entryLogEntries)
             ]
          ++ [ Property False "BODY_LEN" (T.pack (show (length _entryText)))
               | not (null _entryText)
             ]
          ++ case _entryTags of
            [] -> []
            _ ->
              [ Property
                  False
                  "TAGS"
                  ( T.concat $
                      ":"
                        : [ case tag of
                              SpecialTag t -> t <> ":"
                              PlainTag t -> t <> ":"
                            | tag <- _entryTags
                          ]
                  )
              ]
          ++ map
            ( \case
                ClosedStamp tm -> Property False "CLOSED" (showTime tm)
                ScheduledStamp tm -> Property False "SCHEDULED" (showTime tm)
                DeadlineStamp tm -> Property False "DEADLINE" (showTime tm)
            )
            _entryStamps
      )
    ++ concatMap summarizeEntry _entryItems
