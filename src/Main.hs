{-# LANGUAGE DeriveGeneric, OverloadedStrings, RecordWildCards #-}
{-# LANGUAGE TypeApplications                                  #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}
module Main where
import           Control.Arrow          ((>>>))
import           Control.Concurrent
import           Control.Exception
import qualified Control.Foldl          as F
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
import           System.Random

newtype AccTok  = AccTok { accessToken :: ByteString }
  deriving (Read, Show, Eq, Ord)

instance FromJSON AccTok where
  parseJSON = withObject "object" $ \dic ->
    AccTok . T.encodeUtf8 <$> dic .: "access_token"

wait :: Int -> IO ()
wait i0 = do
  i <- floor . (fromIntegral i0 *) <$> randomRIO (0.75, 1.25 :: Double)
  -- hPutStrLn stderr $ "Waiting " ++ show (i `div` 10^3) ++ " millisecs"
  threadDelay i

aggr :: F.Fold (String, [Decl SrcSpanInfo]) (Int, Int, [String], [Decl SrcSpanInfo])
aggr = (,,,) <$> F.length
             <*> F.handles (F.filtered (not . null . snd)) F.length
             <*> F.handles (F.filtered (not . null . snd) . _1) F.list
             <*> F.handles _2 F.mconcat

main :: IO ()
main = do
  hSetBuffering stderr =<< hGetBuffering stdout
  Just (AccTok tok) <- decodeFileStrict' "token.yaml"
  let github = oauth2Token tok
      opts = defaults & auth ?~ github
                      & param "q" .~ ["instance Generic extension:hs extension:lhs"]
  (total, positive, posMods, decs) S.:> () <-
    withStreamMapM 5 maybeParseModule (crawl opts "https://api.github.com/search/code") $
    S.catMaybes >>> F.purely S.fold aggr
  putStrLn $ unwords [ "There are"
                     , show $ length decs
                     , "custom instances."
                     ]
  putStrLn $ unwords [ show positive
                     , "out of"
                     , show total
                     , "modules have custom instances:"
                     ]
  mapM_ putStrLn posMods

maybeParseModule :: String -> IO (Maybe (String, [Decl SrcSpanInfo]))
maybeParseModule url = do
  rsp <- get' url
  -- hPutStrLn stderr $ "Processed: " ++ url
  let src = rsp ^. unpackedChars
  return $ (,) url <$> getCustomGeneric src

getCustomGeneric :: String -> Maybe [Decl SrcSpanInfo]
getCustomGeneric src = do
  i <- maybeResult $ parseModuleWithMode defaultParseMode { extensions = glasgowExts } src
  return $ extractCustomGeneric i


get' :: String -> IO LBS.ByteString
get' =
  untilJust . fmap eitherMaybe . try @HttpException . \url ->
    do -- hPutStrLn stderr $ "accessing: " ++ url;
       wait (10^6); view responseBody <$> get url

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
          liftIO $ wait $ dur * 10^6
          loop url
        Left{} -> liftIO (wait (10^6)) >> loop url
        Right r ->
          forM_ (decode =<< r ^? responseBody) $ \(Items is) -> do
            S.each (map rawUrl is)
            forM_ (r ^? responseLink "rel" "next" . linkURL . unpackedChars) $ \l -> do
              liftIO $ wait . (* 10^6) =<< calcWait r
              loop l

calcWait ::  Response body -> IO Int
calcWait rsp = do
  let remain = rsp ^?! responseHeader "X-RateLimit-Remaining" . unpackedChars . to read
      reset  = rsp ^?! responseHeader "X-RateLimit-Reset" . unpackedChars . to read
      retry  = rsp ^?  responseHeader "Retry-After" . unpackedChars . to read
  now <- (`div` 10^9) . toNanoSecs <$> getTime Realtime
  case retry of
    Just ret -> return ret
    Nothing -> do
      let durSecs = reset - now
          w = ceiling (fromInteger remain / fromInteger durSecs :: Double)
      return $ max 1 $ if durSecs > 0 then w else 0

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
