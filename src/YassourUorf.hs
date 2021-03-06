{-# LANGUAGE OverloadedStrings #-}

module Main
       where 

import Control.Applicative
import Control.Exception
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as BS
import Data.Char
import Data.List
import Data.Maybe
import Numeric
import System.Console.CmdTheLine
import System.FilePath
import System.IO

import qualified Data.Vector.Unboxed as U

import qualified Bio.SamTools.BamIndex as BamIndex
import qualified Bio.SeqLoc.Bed as Bed
import qualified Bio.SamTools.FaIdx as FaIdx
import Bio.SeqLoc.LocRepr
import qualified Bio.SeqLoc.Location as Loc
import Bio.SeqLoc.OnSeq
import qualified Bio.SeqLoc.Position as Pos
import Bio.SeqLoc.Transcript

import Bio.RiboSeq.BamFile
import Bio.RiboSeq.CodonAssignment

doYassourUorf :: Conf -> IO ()
doYassourUorf conf = do asites <- readASiteDelta $ confASite conf
                        bracket (BamIndex.open $ confBamInput conf) BamIndex.close $ \bidx ->
                          withFile (confOutput conf) WriteMode $ \hout ->
                          withFile (confOutProfiles conf) WriteMode $ \hprof ->
                          withFile (confOutBed conf) WriteMode $ \hbed ->
                          mapOverTranscripts (confBeds conf) $ \trx ->
                          doTranscript conf asites bidx trx hout hprof hbed

doTranscript :: Conf -> ASiteDelta -> BamIndex.IdxHandle -> Transcript -> Handle -> Handle -> Handle -> IO ()
doTranscript conf asites bidx trx hout hprof hbed
  = do prof <- transcriptNtProfile asites bidx trx
       msequ <- FaIdx.readLoc (confFasta conf) (location trx) 
       maybe noSequence (\sequ -> maybe noCDS (doProfSequ prof sequ) $ cds trx) msequ
  where noSequence = hPutStrLn stderr $ "Could not get sequence for " ++ (show . unSeqLabel . trxId $ trx)
        noCDS = hPutStrLn stderr $ "No CDS for " ++ (show . unSeqLabel . trxId $ trx)
        doProfSequ prof sequ cdsloc =
          let writeStart = hPutStrLn hout . startLine conf trx prof sequ cdsloc
              writeStartProf = hPutStrLn hprof . startProf conf trx prof sequ cdsloc
              writeBed = BS.hPutStrLn hbed . Bed.transcriptToBedStd
              starts = filter (profIsStart conf prof) $ candStartOffsets conf sequ cdsloc
          in do mapM_ writeStart starts
                mapM_ writeStartProf starts
                mapM_ writeBed $! mapMaybe (uorfTrx conf trx prof sequ cdsloc) starts

candStartOffsets :: Conf -> BS.ByteString -> Loc.ContigLoc -> [Pos.Offset]
candStartOffsets conf sequ cdsloc = candUpstreamStartOffsets sequ cdsloc ++
                                    (if (confDownstream conf) then candDownstreamStartOffsets sequ cdsloc else [])

candUpstreamStartOffsets :: BS.ByteString -> Loc.ContigLoc -> [Pos.Offset]
candUpstreamStartOffsets sequ cdsloc = filter isCandAt [0..cdsStart]
  where cdsStart = Loc.offset5 cdsloc
        isCandAt off = elem (BS.take 3 . BS.drop (fromIntegral off) $ sequ) candStarts
        candStarts = [ "ATG", "CTG", "GTG", "TTG", "AAG", "ACG", "AGG", "ATA", "ATC", "ATT" ]

candDownstreamStartOffsets :: BS.ByteString -> Loc.ContigLoc -> [Pos.Offset]
candDownstreamStartOffsets sequ cdsloc = filter isCandAt [cdsEnd..trxEnd]
  where cdsEnd = snd . Loc.bounds $ cdsloc
        trxEnd = fromIntegral $ BS.length sequ
        isCandAt off = elem (BS.take 3 . BS.drop (fromIntegral off) $ sequ) candStarts
        candStarts = [ "ATG", "CTG", "GTG", "TTG", "AAG", "ACG", "AGG", "ATA", "ATC", "ATT" ]
        
profFrame :: U.Vector Int -> Pos.Offset -> Maybe Double
profFrame cts ntoff
  = case fromIntegral ntoff of
    nt | (nt - 1) < 0 -> Nothing
       | (nt + 1) >= U.length cts -> Nothing
       | otherwise -> let framefract ttl | ttl > 0 = Just $! (fromIntegral $ cts U.! nt) / (fromIntegral ttl)
                                         | otherwise = Nothing
                      in profCodonCount cts ntoff >>= framefract
                       
profCodonCount :: U.Vector Int -> Pos.Offset -> Maybe Int
profCodonCount cts ntoff
  = case fromIntegral ntoff of
    nt | (nt - 1) < 0 -> Nothing
       | (nt + 1) >= U.length cts -> Nothing
       | otherwise -> Just $! (cts U.! (nt - 1)) + (cts U.! nt) + (cts U.! (nt + 1))
                
profStartCounts :: U.Vector Int -> Pos.Offset -> Maybe (Int, Int)
profStartCounts prof nt = liftM2 (,) (profCodonCount prof nt) (profCodonCount prof $  nt + 3)

profIsStart :: Conf -> U.Vector Int -> Pos.Offset -> Bool
profIsStart conf prof nt = maybe False isStart $ profStartCounts prof nt
  where isStart (before, after) = and [ before + after >= confMinCount conf
                                      , (fromIntegral after / fromIntegral before) >= confMinRatio conf
                                      , maybe False (>= confMinFrame conf) $ profFrame prof (nt + 3)
                                      ]

startLine :: Conf -> Transcript -> U.Vector Int -> BS.ByteString -> Loc.ContigLoc -> Pos.Offset -> String
startLine conf trx prof sequ cdsloc ntoff = intercalate "\t" fields
  where nt = fromIntegral ntoff
        fields = [ BS.unpack . unSeqLabel . trxId $ trx
                 , show nt
                 , BS.unpack . BS.take 3 . BS.drop nt $ sequ
                 , startTotal
                 , startRatio
                 , frameRatio
                 , show . Pos.unOff $ ntoff - Loc.offset5 cdsloc
                 , show . Pos.unOff $ ntoff - ((snd . Loc.bounds $ cdsloc) + 1)
                 , ntlen
                 , uorfCount
                 , utrCount
                 , BS.unpack contextbs
                 ] ++ map ctAt [(-1)..4]
        startCounts = profStartCounts prof ntoff
        startTotal = maybe "N/A" (\(b, a) -> show $ a + b) startCounts
        startRatio = maybe "N/A" (\(b, a) -> showFFloat (Just 2) (aoverb (b, a)) "") startCounts
          where aoverb (b, a) = min 10.0 $ logBase 2 (fromIntegral a / fromIntegral b)
        frameRatio = maybe "N/A" (\fr -> showFFloat (Just 2) fr "") $ profFrame prof (ntoff + 3)
        ctAt i | (nt + i >= 0 && nt + i < U.length prof) = show $ prof U.! (nt + i)
               | otherwise = "N/A"
        ntlen = maybe "N/A" (show . (* 3)) . uorfAaLen $ BS.drop nt sequ
        contextbs | nt >= 3 = BS.take 7 . BS.drop (nt - 3) $ sequ
                  | otherwise = "N/A"
        uorfCount = maybe "N/A" show $! uorfAaLen (BS.drop nt sequ) >>= uorfFpCount prof ntoff (Loc.offset5 cdsloc)
        utrCount = maybe "N/A" show $! utrFpCount prof (Loc.offset5 cdsloc)

startProf :: Conf -> Transcript -> U.Vector Int -> BS.ByteString -> Loc.ContigLoc -> Pos.Offset -> String
startProf conf trx prof sequ cdsloc ntoff = intercalate "\t" fields
  where nt = fromIntegral ntoff
        fields = [ BS.unpack . unSeqLabel . trxId $ trx, show nt ] ++ ntCounts
        ntCounts = maybe ["N/A"] ntCountsOver $! uorfAaLen $ BS.drop nt sequ
        ntCountsOver aalen = [ ctAt i | i <- [(-1)..(1 + (3 * (aalen + 1)))] ]
        ctAt i | (nt + i >= 0 && nt + i < U.length prof) = show $ prof U.! (nt + i)
               | otherwise = "N/A"        

uorfTrx :: Conf -> Transcript -> U.Vector Int -> BS.ByteString -> Loc.ContigLoc -> Pos.Offset -> Maybe Transcript
uorfTrx conf trx _prof sequ cdsloc ntoff 
  | end > ntoff = Just $! Transcript { geneId = name, trxId = name, location = uorfseqloc, cds = Just uorfcds }
  | otherwise = Nothing
  where name = toSeqLabel $ BS.concat [ unSeqLabel . trxId $ trx, "_", BS.pack . show $ nt ]
        nt = fromIntegral ntoff
        end = maybe ntoff (uorfEnd ntoff (Loc.offset5 cdsloc)) $ uorfAaLen (BS.drop nt sequ)
        uorfInTrx = Loc.fromStartEnd ntoff end
        uorfloc = fromMaybe (error $ "Cannot pull uORF " ++ reprStr uorfInTrx ++ " out of " ++ reprStr (location trx)) $
                  Loc.clocOutof uorfInTrx (unOnSeq . location $ trx)
        uorfseqloc = OnSeq (onSeqLabel $ location trx) uorfloc
        uorfcds = Loc.fromStartEnd 0 (fromIntegral $ Loc.length uorfInTrx - 1)

uorfAaLen :: BS.ByteString -> Maybe Int
uorfAaLen = findIndex isStop . unfoldr takeCodon
  where isStop codon = (BS.map toUpper codon) `elem` (map BS.pack [ "TAA", "TAG", "TGA" ])
        takeCodon str | BS.null str = Nothing
                      | otherwise = Just $ BS.splitAt 3 str

-- End position in transcript for /quantification/ of uORF
uorfEnd :: Pos.Offset -> Pos.Offset -> Int -> Pos.Offset
uorfEnd nt cdsstart aalen = min (cdsstart - 2) (nt + 3 * (fromIntegral aalen) + 1)

uorfFpCount :: U.Vector Int -> Pos.Offset -> Pos.Offset -> Int -> Maybe Int
uorfFpCount prof nt cdsstart aalen = liftM sum $! sequence codonCounts
  where codonCounts = [ ctat i | i <- [(nt  + 2)..(uorfEnd nt cdsstart aalen)] ]
        ctat off = prof U.!? (fromIntegral off)

utrFpCount :: U.Vector Int -> Pos.Offset -> Maybe Int
utrFpCount prof cdsstart | cdsstart > 1 = Just $! sum [ prof U.! i | i <- [0..(fromIntegral cdsstart  - 2)] ]
                         | otherwise = Nothing

data Conf = Conf { confBamInput :: !FilePath
                 , confOutput :: !FilePath
                 , confBeds :: ![FilePath]
                 , confASite :: !FilePath
                 , confFasta :: !FilePath
                 , confMinCount :: !Int
                 , confMinRatio :: !Double
                 , confMinFrame :: !Double
                 , confDownstream :: !Bool
                 } deriving (Show)

argConf :: Term Conf
argConf = Conf <$>
          argBamInput <*>
          argOutput <*>
          argBeds <*>
          argASite <*>
          argFasta <*>
          argMinCount <*>
          argMinRatio <*>
          argMinFrame <*>
          argDownstream

confOutProfiles :: Conf -> FilePath
confOutProfiles conf = let (base, ext) = splitExtension $ confOutput conf
                       in (base ++ "_profiles") <.> ext

confOutBed :: Conf -> FilePath
confOutBed conf = let (base, ext) = splitExtension $ confOutput conf
                  in (base ++ "_uorfs") <.> "bed"

argBamInput :: Term FilePath
argBamInput = required $ pos 0 Nothing $ posInfo
  { posName = "BAM", posDoc = "BAM format alignment file" }

argOutput :: Term FilePath
argOutput = required $ opt Nothing $ (optInfo ["o", "output"])
  { optName = "OUTBASE", optDoc = "Base filename for output files" }

argBeds :: Term [FilePath]
argBeds = nonEmpty $ optAll [] $ (optInfo ["b", "bed"])
  { optName = "BED", optDoc = "Bed filename" }

argASite :: Term FilePath
argASite = required $ opt Nothing $ (optInfo ["a", "asite"])
  { optName = "ASITEFILE", optDoc = "A site offsets filename" }

argFasta :: Term FilePath
argFasta = required $ opt Nothing $ (optInfo ["f", "fasta"])
  { optName = "FASTA", optDoc = "Indexed fasta file for sequence" }

argMinCount :: Term Int
argMinCount = required $ opt Nothing $ (optInfo ["c", "min-count"])
  { optName = "MIN-COUNT", optDoc = "Minimum total count in -1 and +1 codons" }

argMinRatio :: Term Double
argMinRatio = required $ opt Nothing $ (optInfo ["r", "min-ratio"])
  { optName = "MIN-RATIO", optDoc = "Minimum count ratio, +1 / -1 codons" }

argMinFrame :: Term Double
argMinFrame = required $ opt Nothing $ (optInfo ["z", "min-frame"])
  { optName = "MIN-FRAME", optDoc = "Minimum sub-codon ratio, nt 0 / codon total (-1, 0, +1)" }

argDownstream :: Term Bool
argDownstream = value $ flag $ (optInfo ["d", "downstream"])
  { optDoc = "Search downstream (3' UTR) start sites" }

main :: IO ()
main = run ( yassouruorf, info )
  where yassouruorf = doYassourUorf <$> argConf
        info = defTI { termName = "yassour-uorf"
                     , version = "151002"
                     , termDoc = "Identifies candidate start sites by the method of Yassour"
                     , man = map P [ ""
                                   ]
                     }
