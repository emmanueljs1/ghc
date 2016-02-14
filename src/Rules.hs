module Rules (topLevelTargets, buildRules) where

import Data.Foldable

import Base
import Expression
import GHC
import qualified Rules.Compile
import qualified Rules.Data
import qualified Rules.Dependencies
import qualified Rules.Documentation
import qualified Rules.Generate
import qualified Rules.Resources
import qualified Rules.Cabal
import qualified Rules.Gmp
import qualified Rules.Libffi
import qualified Rules.Library
import qualified Rules.Perl
import qualified Rules.Program
import qualified Rules.Register
import qualified Rules.Setup
import Settings

allStages :: [Stage]
allStages = [minBound ..]

-- | 'need' all top-level build targets
topLevelTargets :: Rules ()
topLevelTargets = do

    want $ Rules.Generate.installTargets

    -- TODO: do we want libffiLibrary to be a top-level target?

    action $ do -- TODO: Add support for all rtsWays
        rtsLib    <- pkgLibraryFile Stage1 rts vanilla
        rtsThrLib <- pkgLibraryFile Stage1 rts threaded
        need [ rtsLib, rtsThrLib ]

    for_ allStages $ \stage ->
        for_ (knownPackages \\ [rts, libffi]) $ \pkg -> action $ do
            let context = vanillaContext stage pkg
            activePackages <- interpretInContext context getPackages
            when (pkg `elem` activePackages) $
                if isLibrary pkg
                then do -- build a library
                    ways <- interpretInContext context getLibraryWays
                    libs <- traverse (pkgLibraryFile stage pkg) ways
                    docs <- interpretInContext context buildHaddock
                    need $ libs ++ [ pkgHaddockFile pkg | docs && stage == Stage1 ]
                else do -- otherwise build a program
                    need [ fromJust $ programPath stage pkg ] -- TODO: drop fromJust

packageRules :: Rules ()
packageRules = do
    resources <- Rules.Resources.resourceRules
    for_ allStages $ \stage ->
        for_ knownPackages $ \pkg ->
            buildPackage resources $ vanillaContext stage pkg

buildPackage :: Rules.Resources.Resources -> Context -> Rules ()
buildPackage = mconcat
    [ Rules.Compile.compilePackage
    , Rules.Data.buildPackageData
    , Rules.Dependencies.buildPackageDependencies
    , Rules.Documentation.buildPackageDocumentation
    , Rules.Generate.generatePackageCode
    , Rules.Library.buildPackageLibrary
    , Rules.Program.buildProgram
    , Rules.Register.registerPackage ]

buildRules :: Rules ()
buildRules = mconcat
    [ Rules.Cabal.cabalRules
    , Rules.Generate.generateRules
    , Rules.Generate.copyRules
    , Rules.Gmp.gmpRules
    , Rules.Libffi.libffiRules
    , Rules.Perl.perlScriptRules
    , Rules.Setup.setupRules
    , Rules.packageRules ]
