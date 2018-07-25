{-# LANGUAGE DeriveGeneric, OverloadedStrings, RecordWildCards #-}
{-# LANGUAGE TypeApplications                                  #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}
module Main where
import           Control.Arrow          ((>>>))
import           Control.Concurrent
import           Control.Exception
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Loops
import           Data.Aeson
import           Data.ByteString        (ByteString)
import qualified Data.ByteString.Char8  as BS
import qualified Data.ByteString.Lazy   as LBS
import           Data.ByteString.Lens
import           Data.Maybe             (fromJust)
import           Data.Monoid
import qualified Data.Text.Encoding     as T
import           GHC.Generics           (Generic)
import           Language.Haskell.Exts
import           Network.HTTP.Client    (HttpException (..),
                                         HttpExceptionContent (..))
import           Network.HTTP.Types
import           Network.Wreq
import           Streaming.Concurrent
import qualified Streaming.Prelude      as S
import           System.Clock
import           System.IO

newtype AccTok  = AccTok { accessToken :: ByteString }
  deriving (Read, Show, Eq, Ord)

instance FromJSON AccTok where
  parseJSON = withObject "object" $ \dic ->
    AccTok . T.encodeUtf8 <$> dic .: "access_token"

main :: IO ()
main = do
  Just (AccTok tok) <- decodeFileStrict' "token.yaml"
  let github = oauth2Token tok
      opts = defaults & auth ?~ github
                      & param "q" .~ ["instance Generic extension:hs extension:lhs"]
  i <- withStreamMapM 5 maybeParseModule (crawl opts "https://api.github.com/search/code") $
       S.catMaybes >>> S.toList_
  print i
  putStrLn $ unwords [ "There are"
                     , show $ getSum $ foldMap (Sum . length . snd) i
                     , "custom instances."
                     ]
  putStrLn $ unwords [ show $ length $ filter (not . null . snd) i
                     , "out of"
                     , show $ length i
                     , "modules have custom instances."
                     ]

maybeParseModule :: String -> IO (Maybe (String, [Decl SrcSpanInfo]))
maybeParseModule url = do
  rsp <- get' url
  hPutStrLn stderr $ "Processed: " ++ url
  let src = rsp ^. unpackedChars
  return $ getCustomGeneric src

getCustomGeneric :: String -> Maybe (String, [Decl SrcSpanInfo])
getCustomGeneric src = do
  i <- maybeResult $ parseModuleWithMode defaultParseMode { extensions = glasgowExts } src
  return (src, extractCustomGeneric i)


get' :: String -> IO LBS.ByteString
get' =
  untilJust . fmap eitherMaybe . try @HttpException . \url ->
    do hPutStrLn stderr $ "accessing: " ++ url; threadDelay (10^6); view responseBody <$> get url

eitherMaybe :: Either HttpException LBS.ByteString -> Maybe LBS.ByteString
eitherMaybe (Right a) = Just a
eitherMaybe (Left (HttpExceptionRequest _ (StatusCodeException rsp _)))
  | rsp ^. responseStatus == status404 = Just ""
eitherMaybe _ = Nothing

maybeResult :: ParseResult a -> Maybe a
maybeResult (ParseOk a) = Just a
maybeResult _           = Nothing

data Item = Item { itemPath       :: String
                 , itemRepository :: Repository
                 , itemUrl        :: String
                 }
  deriving (Read, Show, Eq, Ord, Generic)

rawUrl :: Item -> String
rawUrl Item{..} =
  mconcat [repoHtmlUrl itemRepository, "/raw/", itemSha, "/", itemPath ]
  where
    itemSha = BS.unpack $ fromJust $ join $
              lookup "ref" $ snd $ decodePath $ BS.pack itemUrl

newtype Repository = Repo { repoHtmlUrl :: String }
  deriving (Read, Show, Eq, Ord, Generic)

newtype Items  = Items { items :: [Item] }
  deriving (Read, Show, Eq, Ord, Generic)

aeOpts :: Data.Aeson.Options
aeOpts =  defaultOptions { fieldLabelModifier = camelTo2 '_' . drop 4 }

instance FromJSON Repository where
  parseJSON = genericParseJSON aeOpts

instance FromJSON Item where
  parseJSON = genericParseJSON aeOpts

instance FromJSON Items where
  parseJSON = genericParseJSON  aeOpts { fieldLabelModifier = camelTo2 '_' }

crawl :: MonadIO m
      => Network.Wreq.Options -> String -> S.Stream (S.Of String) m ()
crawl opt = loop
  where
    loop url = do
      er <- liftIO $ try $ getWith opt url
      case er of
        Left (HttpExceptionRequest _ (StatusCodeException r _)) -> do
          let dur = r ^?! responseHeader "Retry-After" . unpackedChars . to read
          liftIO $ threadDelay $ dur * 10^6
          loop url
        Left{} -> liftIO (threadDelay (10^6)) >> loop url
        Right r ->
          forM_ (decode =<< r ^? responseBody) $ \(Items is) -> do
            S.each (map rawUrl is)
            forM_ (r ^? responseLink "rel" "next" . linkURL . unpackedChars) $ \l -> do
              liftIO $ threadDelay . (* 10^6) =<< calcWait r
              loop l

calcWait ::  Response body -> IO Int
calcWait rsp = do
  let remain = rsp ^?! responseHeader "X-RateLimit-Remaining" . unpackedChars . to read
      reset  = rsp ^?! responseHeader "X-RateLimit-Reset" . unpackedChars . to read
      retry  = rsp ^? responseHeader "Retry-After" . unpackedChars . to read
  now <- (`div` 10^9) . toNanoSecs <$> getTime Realtime
  case retry of
    Just ret -> return ret
    Nothing -> do
      let durSecs = reset - now
          wait = ceiling (fromInteger remain / fromInteger durSecs :: Double)
      return $ max 1 $ if durSecs > 0 then wait else 0

extractCustomGeneric :: Module l -> [Decl l]
extractCustomGeneric (Module _ _ _ _ decs) =
  filter isInstanceGeneric decs
  where
    isInstanceGeneric (InstDecl _ _ (IRule _ _ _ (IHApp _ (IHCon _ n) _)) Just {})
      | nameLast n == "Generic" = True
    isInstanceGeneric _         = False
extractCustomGeneric _ = []

nameLast :: QName l -> String
nameLast (UnQual _ n)  = prettyPrint  n
nameLast (Qual _ _ n)  = prettyPrint n
nameLast (Special _ n) = prettyPrint n
