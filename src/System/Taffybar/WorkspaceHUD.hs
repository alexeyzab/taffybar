{-# LANGUAGE ScopedTypeVariables, ExistentialQuantification, RankNTypes #-}
-----------------------------------------------------------------------------
-- |
-- Module      : System.Taffybar.WorkspaceHUD
-- Copyright   : (c) Ivan A. Malison
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : Ivan A. Malison
-- Stability   : unstable
-- Portability : unportable
-----------------------------------------------------------------------------

module System.Taffybar.WorkspaceHUD (
  IconInfo(..),
  WWC(..),
  Workspace(..),
  WorkspaceContentsController(..),
  WorkspaceButtonController(..),
  WorkspaceUnderlineController(..),
  WorkspaceHUDConfig(..),
  WorkspaceWidgetController(..),
  buildButtonController,
  buildContentsController,
  buildUnderlineButtonController,
  buildUnderlineController,
  buildWorkspaceHUD,
  buildWorkspaces,
  defaultWorkspaceHUDConfig,
  getWorkspaceToWindows,
  windowTitleClassIconGetter
) where

import           Control.Applicative
import qualified Control.Concurrent.MVar as MV
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.Char as S
import qualified Data.Foldable as F
import qualified Data.Map as M
import qualified Data.MultiMap as MM
import qualified Data.Set as Set
import qualified Graphics.UI.Gtk as Gtk
import qualified Graphics.UI.Gtk.Abstract.Widget as W
import qualified Graphics.UI.Gtk.Layout.Table as T
import           Graphics.X11.Xlib.Extras
import           System.Information.EWMHDesktopInfo
import           System.Taffybar.IconImages
import           System.Taffybar.Pager
import           Text.Printf

data WorkspaceState
  = Active
  | Visible
  | Hidden
  | Empty
  deriving (Show, Eq)

data IconInfo
  = IIEWMH EWMHIcon
  | IIFilePath FilePath
  | IIColor ColorRGBA
  | IINone
  deriving (Eq, Show)

transparentInfo :: IconInfo
transparentInfo = IIColor $ (0, 0, 0, 0)

data WindowData = WindowData { windowId :: X11Window
                             , windowTitle :: String
                             , windowClass :: String
                             , windowUrgent :: Bool
                             } deriving (Show, Eq)

data WidgetUpdate = WorkspaceUpdate Workspace | IconUpdate [X11Window]

data Workspace =
  Workspace { workspaceIdx :: WorkspaceIdx
            , workspaceName :: String
            , workspaceState :: WorkspaceState
            , windows :: [WindowData]
            } deriving (Show, Eq)

class WorkspaceWidgetController wc where
  updateWidget :: wc -> WidgetUpdate -> IO wc
  getWidget :: wc -> Gtk.Widget

data WWC = forall a. WorkspaceWidgetController a => WWC a

instance WorkspaceWidgetController WWC where
  getWidget (WWC wc) = getWidget wc
  updateWidget (WWC wc) workspace =
    WWC <$> updateWidget wc workspace

type ControllerConstructor = Context -> Workspace -> IO WWC
type ParentControllerConstructor = ControllerConstructor -> ControllerConstructor

data WorkspaceHUDConfig =
  WorkspaceHUDConfig
  { widgetBuilder :: ControllerConstructor
  , widgetGap :: Int
  , windowIconSize :: Int
  , underlineHeight :: Int
  , minWSWidgetSize :: Maybe Int
  , underlinePadding :: Int
  , maxIcons :: Maybe Int
  , minIcons :: Int
  , getIconInfo :: WorkspaceHUDConfig -> WindowData -> IO IconInfo
  , labelSetter :: Workspace -> String
  , updateIconsOnTitleChange :: Bool
  }

defaultWorkspaceHUDConfig :: WorkspaceHUDConfig
defaultWorkspaceHUDConfig =
  WorkspaceHUDConfig { widgetBuilder = buildUnderlineButtonController
                     , widgetGap = 0
                     , windowIconSize = 16
                     , underlineHeight = 4
                     , minWSWidgetSize = Just 30
                     , underlinePadding = 1
                     , maxIcons = Nothing
                     , minIcons = 0
                     , getIconInfo = defaultGetIconInfo
                     , labelSetter = workspaceName
                     , updateIconsOnTitleChange = True
                     }

data Context =
  Context { controllersVar :: MV.MVar (M.Map WorkspaceIdx WWC)
          , workspacesVar :: MV.MVar (M.Map WorkspaceIdx Workspace)
          , hudWidget :: Gtk.HBox
          , hudConfig :: WorkspaceHUDConfig
          , hudPager :: Pager
          }

updateVar :: MV.MVar a -> (a -> IO a) -> IO a
updateVar var modify = MV.modifyMVar var $ fmap (\a -> (a, a)) . modify

updateWorkspacesVar :: MV.MVar (M.Map WorkspaceIdx Workspace)
                    -> IO (M.Map WorkspaceIdx Workspace)
updateWorkspacesVar workspacesRef = updateVar workspacesRef buildWorkspaces

getWorkspaceToWindows :: IO (MM.MultiMap WorkspaceIdx X11Window)
getWorkspaceToWindows =
  withDefaultCtx getWindows >>=
  foldM
    (\theMap window ->
       MM.insert <$> withDefaultCtx (getWorkspace window)
                 <*> pure window <*> pure theMap)
    MM.empty

getUrgentWindows :: IO [X11Window]
getUrgentWindows = withDefaultCtx (getWindows >>= filterM isWindowUrgent)

getWindowData :: [X11Window] -> X11Window -> IO WindowData
getWindowData urgentWindows window = withDefaultCtx $
  do
    wTitle <- getWindowTitle window
    wClass <- getWindowClass window
    return $ WindowData { windowId = window
                        , windowTitle = wTitle
                        , windowClass = wClass
                        , windowUrgent = elem window urgentWindows
                        }

buildWorkspaces :: M.Map WorkspaceIdx Workspace -> IO (M.Map WorkspaceIdx Workspace)
buildWorkspaces _ = do
  names <- withDefaultCtx getWorkspaceNames
  workspaceToWindows <- getWorkspaceToWindows
  urgentWindows <- getUrgentWindows
  active:visible <- withDefaultCtx getVisibleWorkspaces

  let
    getWorkspaceState idx ws
        | idx == active = Active
        | elem idx visible = Visible
        | null ws = Empty
        | otherwise = Hidden

  foldM (\theMap (idx, name) ->
           do
             let ws = MM.lookup idx workspaceToWindows
             windowInfos <- mapM (getWindowData urgentWindows) ws
             return $ M.insert idx
                    Workspace { workspaceIdx = idx
                              , workspaceName = name
                              , workspaceState = getWorkspaceState idx ws
                              , windows = windowInfos
                              } theMap) M.empty names

addWidgetsToTopLevel :: Context -> IO ()
addWidgetsToTopLevel Context { controllersVar = controllersRef
                             , hudWidget = cont
                             } = do
  controllersMap <- MV.readMVar controllersRef
  -- Elems returns elements in ascending order of their keys so this will always
  -- add the widgets in the correct order
  mapM_ addWidget $ M.elems controllersMap
  -- XXX: Does this belong somewhere else
  Gtk.widgetShowAll cont
    where addWidget controller =
            do
              let widget = getWidget controller
              Gtk.containerAdd cont widget
              Gtk.boxPackStart cont widget Gtk.PackNatural 0

buildWorkspaceHUD :: WorkspaceHUDConfig -> Pager -> IO Gtk.Widget
buildWorkspaceHUD cfg pager = do
  cont <- Gtk.hBoxNew False (widgetGap cfg)
  controllersRef <- MV.newMVar M.empty
  workspacesRef <- MV.newMVar M.empty
  let context = Context { controllersVar = controllersRef
                        , workspacesVar = workspacesRef
                        , hudWidget = cont
                        , hudConfig = cfg
                        , hudPager = pager
                        }

  -- This will actually create all the widgets
  updateAllWorkspaceWidgets context

  mapM_ (subscribe pager (onActiveChanged context))
        [ "_NET_CURRENT_DESKTOP"
        , "_NET_WM_DESKTOP"
        , "_NET_DESKTOP_NAMES"
        , "_NET_NUMBER_OF_DESKTOPS"
        , "WM_HINTS"
        ]

  subscribe pager (onIconChanged context) "_NET_WM_ICON"

  return $ Gtk.toWidget cont

updateAllWorkspaceWidgets :: Context -> IO ()
updateAllWorkspaceWidgets c@Context { workspacesVar = workspacesRef} = do
  workspacesMap <- updateWorkspacesVar workspacesRef
  updateWorkspaceControllers c

  let updateController idx controller =
        maybe (return controller)
              (updateWidget controller . WorkspaceUpdate) $
              M.lookup idx workspacesMap
  doWidgetUpdate c updateController

doWidgetUpdate :: Context -> (WorkspaceIdx -> WWC -> IO WWC) -> IO ()
doWidgetUpdate Context { controllersVar = controllersRef } updateController =
  MV.modifyMVar_ controllersRef $ \controllers -> do
    controllersList <-
      mapM
      (\(idx, controller) -> do
         newController <- (updateController idx controller)
         return (idx, newController)) $
      M.toList controllers
    return $ M.fromList controllersList

updateWorkspaceControllers :: Context -> IO ()
updateWorkspaceControllers c@Context { controllersVar = controllersRef
                                     , workspacesVar = workspacesRef
                                     , hudWidget = cont
                                     , hudConfig = cfg
                                     }  = do
  workspacesMap <- MV.readMVar workspacesRef
  controllersMap <- MV.readMVar controllersRef
  let newWorkspacesSet = M.keysSet workspacesMap
      existingWorkspacesSet = M.keysSet controllersMap
  when (existingWorkspacesSet /= newWorkspacesSet) $ do
    let addWorkspaces = (Set.difference newWorkspacesSet existingWorkspacesSet)
        removeWorkspaces = (Set.difference existingWorkspacesSet newWorkspacesSet)
        builder = (widgetBuilder cfg) c
    MV.modifyMVar_ controllersRef $ \controllers -> do
      let oldRemoved = F.foldl (flip M.delete) controllers removeWorkspaces
          buildController idx =
              case (M.lookup idx workspacesMap) of
                Just ws -> builder ws
          buildAndAddController theMap idx = M.insert idx <$> buildController idx <*> pure theMap
      foldM buildAndAddController oldRemoved $ Set.toList addWorkspaces
    -- Clear the container and repopulate it
    Gtk.containerForeach cont (Gtk.containerRemove cont)
    addWidgetsToTopLevel c

onActiveChanged :: Context -> Event -> IO ()
onActiveChanged context _ =
  Gtk.postGUIAsync $ updateAllWorkspaceWidgets context

onIconChanged :: Context -> Event -> IO ()
onIconChanged context event =
  case event of
    PropertyEvent { ev_window = wid } ->
      do
        let update = IconUpdate [wid]
        doWidgetUpdate context (\_ c -> updateWidget c update)
    _ -> return ()


data IconWidget = IconWidget { iconContainer :: Gtk.EventBox
                             , iconImage :: Gtk.Image
                             , iconWindow :: MV.MVar (Maybe WindowData)
                             }

data WorkspaceContentsController = WorkspaceContentsController
  { containerEbox :: Gtk.EventBox
  , container :: Gtk.HBox
  , label :: Gtk.Label
  , iconImages :: [IconWidget]
  , contentsWorkspace :: Workspace
  , contentsContext :: Context
  }

contentsConfig :: WorkspaceContentsController -> WorkspaceHUDConfig
contentsConfig = hudConfig . contentsContext

buildContentsController :: ControllerConstructor
buildContentsController context ws = do
  lbl <- Gtk.labelNew (Nothing :: Maybe String)
  hbox <- Gtk.hBoxNew False 0
  ebox <- Gtk.eventBoxNew
  Gtk.containerAdd hbox lbl
  Gtk.containerAdd ebox hbox
  let tempController =
        WorkspaceContentsController { containerEbox = ebox
                                    , container = hbox
                                    , label = lbl
                                    , iconImages = []
                                    , contentsWorkspace =
                                      ws { windows = []
                                         , workspaceName = workspaceName ws ++ "fake"
                                         }
                                    , contentsContext = context
                                    }
  WWC <$> updateWidget tempController (WorkspaceUpdate ws)

instance WorkspaceWidgetController WorkspaceContentsController where
  getWidget cc = Gtk.toWidget $ containerEbox cc
  updateWidget cc (WorkspaceUpdate newWorkspace) = do
    let currentWorkspace = contentsWorkspace cc
        cfg = contentsConfig cc
        getLabel = labelSetter cfg

    when ((getLabel currentWorkspace) /= (getLabel newWorkspace)) $
         Gtk.labelSetMarkup (label cc) (getLabel newWorkspace)

    newImages <- updateImages cc newWorkspace

    setContainerWidgetNames cc newWorkspace

    maybe (return ()) (updateMinSize $ Gtk.toWidget $ container cc) $
          minWSWidgetSize cfg

    return cc { contentsWorkspace = newWorkspace
              , iconImages = newImages
              }
  updateWidget cc (IconUpdate updatedIcons) =
    updateWindowIconsById cc updatedIcons >> return cc

updateWindowIconsById :: WorkspaceContentsController
                      -> [X11Window]
                      -> IO ()
updateWindowIconsById wcc windowIds =
  mapM_ (maybeUpdateWindowIcon) $ iconImages wcc
  where
    maybeUpdateWindowIcon widget =
      do
        info <- MV.readMVar $ iconWindow widget
        when (maybe False ((flip elem windowIds) . windowId) info) $
         updateIconWidget wcc widget info True False

setContainerWidgetNames :: WorkspaceContentsController -> Workspace -> IO ()
setContainerWidgetNames wcc ws = do
  let getWName = getWidgetName ws
      contentsName = getWName "contents"
      labelName = getWName "label"
  Gtk.widgetSetName (containerEbox wcc) contentsName
  Gtk.widgetSetName (label wcc) labelName

updateMinSize :: Gtk.Widget -> Int  -> IO ()
updateMinSize widget minWidth = do
  W.widgetSetSizeRequest widget (-1) (-1)
  W.Requisition w _ <- W.widgetSizeRequest widget
  when (w < minWidth) $ W.widgetSetSizeRequest widget minWidth  $ -1

defaultGetIconInfo :: WorkspaceHUDConfig -> WindowData -> IO IconInfo
defaultGetIconInfo cfg w = do
  icons <- withDefaultCtx $ getWindowIcons $ windowId w
  return $ if (null icons)
           then IINone
           else IIEWMH $ selectEWMHIcon (windowIconSize cfg) icons

windowTitleClassIconGetter
  :: Bool
  -> (String -> String -> IconInfo)
  -> (WorkspaceHUDConfig -> WindowData -> IO IconInfo)
windowTitleClassIconGetter preferCustom customIconF = fn
    where fn cfg w@WindowData { windowTitle = wTitle
                              , windowClass = wClass
                              } =
            do
              let customResult = customIconF wTitle wClass
              defaultResult <- defaultGetIconInfo cfg w
              let first = if preferCustom then customResult else defaultResult
              let second = if preferCustom then defaultResult else customResult
              return $ case first of
                         IINone -> second
                         _ -> first

updateImages :: WorkspaceContentsController -> Workspace -> IO [IconWidget]
updateImages wcc ws = do
  -- XXX: Only one of the two things being zipped can be an infinite list, which
  -- is why this newImagesNeeded contortion is needed.
  let justWindows = map Just $ windows ws
      windowDatas =
        if newImagesNeeded
          then justWindows ++ (replicate (minIcons cfg - length justWindows) Nothing)
          else (justWindows ++ repeat Nothing)
      transparentOnNones = (replicate (minIcons cfg) True) ++ repeat False

  newImgs <- sequence $ zipWith3 updateIconWidget' getImgs windowDatas transparentOnNones
  when newImagesNeeded $ Gtk.widgetShowAll $ container wcc

  return newImgs

  where
    cfg = contentsConfig wcc
    updateIconWidget' getImage wdata ton = do
      -- XXX: This is a hack to make sure that transparent minIcons images get
      -- populated
      let force = wdata == Nothing && newImagesNeeded && ton
      iconWidget <- getImage
      _ <- updateIconWidget wcc iconWidget wdata force ton
      return iconWidget
    existingImages = (map return $ iconImages wcc)
    infiniteImages =
      existingImages ++
      (repeat $ do
         iw <- buildIconWidget
         Gtk.containerAdd (container wcc) $ iconContainer iw
         return iw)
    windowCount = length $ windows ws
    maxNeeded = maybe windowCount (min windowCount) $ maxIcons cfg
    newImagesNeeded = length existingImages < max (minIcons cfg) maxNeeded
    imgSrcs =
      if newImagesNeeded
        then infiniteImages
        else existingImages
    getImgs = case maxIcons $ contentsConfig wcc of
                Just theMax -> take theMax imgSrcs
                Nothing -> imgSrcs

buildIconWidget :: IO IconWidget
buildIconWidget = do
  img <- Gtk.imageNew
  ebox <- Gtk.eventBoxNew
  windowVar <- MV.newMVar Nothing
  Gtk.containerAdd ebox img
  _ <- Gtk.on ebox Gtk.buttonPressEvent $ liftIO $ do
                    info <- MV.readMVar windowVar
                    case info of
                      Just updatedInfo ->
                        withDefaultCtx $ focusWindow $ windowId updatedInfo
                      _ -> return ()
                    return True
  return IconWidget { iconContainer = ebox
                    , iconImage = img
                    , iconWindow = windowVar
                    }

updateIconWidget
  :: WorkspaceContentsController
  -> IconWidget
  -> Maybe WindowData
  -> Bool
  -> Bool
  -> IO ()
updateIconWidget wcc IconWidget { iconContainer = iconButton
                                , iconImage = image
                                , iconWindow = windowRef
                                } windowData forceUpdate transparentOnNone =
  MV.modifyMVar_ windowRef $ \currentData ->
    let requireFullEqualityForSkip = updateIconsOnTitleChange $ contentsConfig wcc
        sameWindow = (windowId <$> currentData) == (windowId <$> windowData)
        dataRequiresUpdate =
          (requireFullEqualityForSkip && (currentData /= windowData)) ||
          not sameWindow
    in
    (when (forceUpdate || dataRequiresUpdate) setIconWidgetProperties)
    >> return windowData
      where
        setIconWidgetProperties = do
          let cfg = contentsConfig wcc
          info <- case windowData of
                    Just dat -> (getIconInfo cfg) cfg dat
                    Nothing -> return IINone
          let imgSize = windowIconSize $ contentsConfig wcc
              urgentStr = if (maybe False windowUrgent windowData)
                          then "urgent"
                          else "normal"

              iconInfo = case info of
                           IINone -> if transparentOnNone
                                     then transparentInfo
                                     else IINone
                           _ -> info

          mpixBuf <- getPixBuf imgSize iconInfo
          setImage imgSize image mpixBuf

          let widgetName = printf "Workspace-icon-%s-%s"
                           (show $ maybe 0 windowId windowData) urgentStr
          Gtk.widgetSetName iconButton (widgetName :: String)

-- | Sets an image based on the image choice (EWMHIcon, custom file, and fill color).
setImage :: Int -> Gtk.Image -> Maybe Gtk.Pixbuf -> IO ()
setImage imgSize img pixBuf =
  case pixBuf of
    Just pixbuf -> do
      scaledPixbuf <- scalePixbuf imgSize pixbuf
      Gtk.imageSetFromPixbuf img scaledPixbuf
    Nothing -> Gtk.imageClear img

-- | Get the appropriate image given an ImageChoice value
getPixBuf :: Int -> IconInfo -> IO (Maybe Gtk.Pixbuf)
getPixBuf imgSize imgChoice = gpb imgChoice
  where
    gpb (IIEWMH icon) = Just <$> pixBufFromEWMHIcon icon
    gpb (IIFilePath file) = Just <$> pixBufFromFile imgSize file
    gpb (IIColor color) = Just <$> pixBufFromColor imgSize color
    gpb _ = return Nothing

data WorkspaceButtonController =
  WorkspaceButtonController { button :: Gtk.EventBox
                            , buttonWorkspace :: Workspace
                            , contentsController :: WWC
                            }

buildButtonController :: ParentControllerConstructor
buildButtonController contentsBuilder context workspace = do
  ebox <- Gtk.eventBoxNew
  cc <- contentsBuilder context workspace
  Gtk.containerAdd ebox $ getWidget cc
  _ <- Gtk.on ebox Gtk.buttonPressEvent $ switch $ workspaceIdx workspace
  return $ WWC WorkspaceButtonController { button = ebox
                                         , buttonWorkspace = workspace
                                         , contentsController = cc
                                         }

switch :: (MonadIO m) => WorkspaceIdx -> m Bool
switch idx = do
  liftIO $ withDefaultCtx (switchToWorkspace idx)
  return True

instance WorkspaceWidgetController WorkspaceButtonController
  where
    getWidget wbc = Gtk.toWidget $ button wbc
    updateWidget wbc update = do
      newContents <- updateWidget (contentsController wbc) update
      return wbc { contentsController = newContents }

data WorkspaceUnderlineController =
  WorkspaceUnderlineController { table :: T.Table
                      -- XXX: An event box is used here because we need to
                      -- change the background
                      , underline :: Gtk.EventBox
                      , overlineController :: WWC
                      }

buildUnderlineController :: ParentControllerConstructor
buildUnderlineController contentsBuilder context workspace = do
  let cfg = hudConfig context
  t <- T.tableNew 2 1 False
  u <- Gtk.eventBoxNew
  cc <- contentsBuilder context workspace

  W.widgetSetSizeRequest u (-1) $ underlineHeight cfg

  T.tableAttach t (getWidget cc) 0 1 0 1 [T.Expand] [T.Expand] 0 0
  T.tableAttach t u 0 1 1 2 [T.Fill] [T.Shrink] (underlinePadding cfg) 0

  return $ WWC WorkspaceUnderlineController { table = t
                                   , underline = u
                                   , overlineController = cc
                                   }

instance WorkspaceWidgetController WorkspaceUnderlineController
  where
    getWidget uc = Gtk.toWidget $ table uc
    updateWidget uc wu@(WorkspaceUpdate workspace) =
      (Gtk.widgetSetName (underline uc) $ getWidgetName workspace "underline") >>
      (updateUnderline uc wu)
    updateWidget a b = updateUnderline a b

updateUnderline :: WorkspaceUnderlineController -> WidgetUpdate -> IO WorkspaceUnderlineController
updateUnderline uc u = do
  newContents <- updateWidget (overlineController uc) u
  return uc { overlineController = newContents }

getWidgetName :: Workspace -> String -> String
getWidgetName ws wname =
  printf
    "Workspace-%s-%s-%s"
    wname
    (workspaceName ws)
    (map S.toLower $ show $ workspaceState ws)

buildUnderlineButtonController :: ControllerConstructor
buildUnderlineButtonController =
  buildButtonController (buildUnderlineController buildContentsController)
