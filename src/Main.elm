port module Main exposing (Model, Msg(..), init, main, subscriptions, update, view, viewLink)

import Browser
import Browser.Dom as Dom
import Browser.Navigation as Nav
import Draft exposing (Draft)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Icons
import Json.Decode as D
import Json.Encode as E
import Llm
import Random
import Recipe exposing (Recipe)
import Route exposing (Route(..))
import SavedRecipe exposing (SavedRecipe)
import Server
import Settings exposing (Settings)
import Task
import Time
import TimeFormat
import Url



-- MAIN


main : Program E.Value Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }



-- MODEL


type alias Model =
    { navKey : Nav.Key
    , route : Route
    , timezone : Time.Zone
    , settings : SettingsEditor
    , connection : Connection -- where the stock and saved recipes live
    , serverReachable : Bool -- while Connected: whether the last check reached it
    , serverKnown : Bool -- localStorage (`clerk.server`): this browser has loaded data from the server before
    , pendingWrite : Maybe Write -- sent to the server, waiting on its reply
    , writeError : Maybe ( Write, String ) -- the last write that failed, shown on its page
    , stock : Draft String -- saved: localStorage (`clerk.stock`) or the server
    , prompt : String
    , requestState : RequestState
    , activeRecipe : Maybe Recipe
    , assistantResponse : Maybe String -- the model's note about `activeRecipe`
    , forkedFrom : Maybe SavedRecipe.ForkOrigin -- the saved recipe `activeRecipe` was forked from
    , savedRecipes : List SavedRecipe -- localStorage (`clerk.recipes`) or the server, oldest first
    , recipeEdit : Maybe RecipeEdit -- a saved recipe in edit mode on its page
    , pendingConfirm : Maybe Confirmable -- waiting on the browser's confirm dialog
    }


{-| Where the stock and saved recipes live (clerk.md §1). Settled once at
startup, from whether the self-host server answers `api/health`, and never
swapped mid-session. A server this browser has loaded from before that doesn't
answer is down, not absent: the cached page (`sw.js`) still opens, but falling
back to localStorage would show stale data and keep saves off the server.
-}
type Connection
    = Loading -- checking for the server, then loading its data
    | Disconnected -- localStorage
    | Connected -- the self-host server
    | ServerUnreachable -- a known server that didn't answer; checked again until it does
    | LoadFailed String -- the server answered, but its data didn't load


{-| A change to the stock or the saved recipes. Stored in localStorage at once;
on the server, the model only changes once the server confirms it
(`applyWrite`), so a failed save loses nothing.
-}
type Write
    = WriteStock String
    | WriteNewRecipe SavedRecipe -- saved from the generator
    | WriteEdit SavedRecipe -- an edit saved on the recipe's page
    | WriteDelete String -- saved recipe id


{-| A saved recipe being edited on its page. Nothing is stored until Save;
`draft.saved` is the recipe as it was when editing started.
-}
type alias RecipeEdit =
    { id : String
    , draft : Draft Recipe
    }


{-| Which of a recipe's lists an edit applies to.
-}
type RecipeList
    = Ingredients
    | Steps


{-| An action that asks "are you sure?" first, with the browser's confirm
dialog (`askConfirm` port). It's kept in the model while the dialog is open,
so the answer (`confirmed` port) only needs to be yes or no.
-}
type Confirmable
    = ClearGenerator
    | DeleteRecipe String -- saved recipe id
    | ForkRecipe String -- saved recipe id; asks only if it would replace the generator's recipe
    | DiscardEdit -- asks only if the edit has changes


type RequestState
    = Idle
    | Awaiting
        { sentPrompt : String -- restored to the chat box if the request fails
        , status : String -- shown as the chat box's placeholder
        , secondsLeft : Int -- until `status` changes
        , glyphIndex : Int -- into `cookingGlyphs`, advanced every second
        , connection : Llm.Connection -- kept for the retry
        , messages : List Llm.Message -- the conversation sent so far
        , isRetry : Bool -- the one corrective retry has been sent
        }
    | Failed String


isAwaiting : RequestState -> Bool
isAwaiting requestState =
    case requestState of
        Awaiting _ ->
            True

        _ ->
            False


{-| Shown before the status word, one per second in order, so there's visible
activity between word changes without the word itself moving.
-}
cookingGlyphs : List String
cookingGlyphs =
    [ "🍳", "🥘", "🍲", "🥕", "🧄", "🧅", "🍅", "🥔", "🔪", "🥄" ]


{-| Cycled through in the chat box while a recipe generates, after starting on
"Generating".
-}
cookingWords : List String
cookingWords =
    [ "Shaking"
    , "Baking"
    , "Simmering"
    , "Sautéing"
    , "Whisking"
    , "Chopping"
    , "Stirring"
    , "Kneading"
    , "Braising"
    , "Roasting"
    , "Seasoning"
    , "Marinating"
    , "Folding"
    , "Mincing"
    , "Searing"
    , "Tasting"
    , "Plating"
    , "Glazing"
    , "Poaching"
    , "Toasting"
    ]


glyphAt : Int -> String
glyphAt index =
    List.drop (modBy (List.length cookingGlyphs) index) cookingGlyphs
        |> List.head
        |> Maybe.withDefault ""


{-| A random cooking word other than the current one, so it visibly changes,
and how many seconds (2 or 3) to show it for.
-}
nextStatus : String -> Random.Generator ( String, Int )
nextStatus current =
    Random.pair
        (case List.filter ((/=) current) cookingWords of
            first :: rest ->
                Random.uniform first rest

            [] ->
                Random.constant current
        )
        (Random.int 2 3)


{-| Like `Draft`, but the form holds raw strings that only become `Settings`
once they parse. `saved` is `Nothing` until a provider is set up.
-}
type alias SettingsEditor =
    { saved : Maybe Settings -- localStorage (`clerk.settings`)
    , form : Settings.Form
    }


init : E.Value -> Url.Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        ( loaded, loadCmd ) =
            case D.decodeValue flagsDecoder flags of
                Ok stored ->
                    ( stored, Cmd.none )

                Err err ->
                    ( { stock = "", settings = Settings.emptyForm, recipes = [], generated = Nothing, forkedFrom = Nothing, serverKnown = False }
                    , logError ("Decode err: " ++ D.errorToString err)
                    )

        ( model, routeCmd ) =
            routeTo (Route.fromUrl url)
                { navKey = key
                , route = Route.Create
                , timezone = Time.utc
                , settings = { saved = Result.toMaybe (Settings.parse loaded.settings), form = loaded.settings }
                , connection = Loading
                , serverReachable = True
                , serverKnown = loaded.serverKnown
                , pendingWrite = Nothing
                , writeError = Nothing

                -- replaced by the server's, if it turns out to be there
                , stock = Draft.init loaded.stock
                , prompt = ""
                , requestState = Idle
                , activeRecipe = Maybe.map .recipe loaded.generated
                , assistantResponse =
                    -- a forked recipe has no response and is stored with ""
                    Maybe.map .response loaded.generated
                        |> Maybe.andThen
                            (\response ->
                                if String.isEmpty response then
                                    Nothing

                                else
                                    Just response
                            )
                , forkedFrom = loaded.forkedFrom
                , savedRecipes = loaded.recipes
                , recipeEdit = Nothing
                , pendingConfirm = Nothing
                }
    in
    ( model
    , Cmd.batch [ loadCmd, routeCmd, Server.checkHealth GotHealth, Task.perform GotTimezone Time.here ]
    )


routeTo : Route -> Model -> ( Model, Cmd Msg )
routeTo route model =
    case route of
        Route.NotFound ->
            -- redirect to recipe generator page
            ( { model | route = Route.Create }
            , Nav.replaceUrl model.navKey (Route.toFragment Route.Create)
            )

        _ ->
            ( { model | route = route }, Cmd.none )



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url.Url
    | GotTimezone Time.Zone
    | GotHealth Bool
    | GotServerData (Result String Server.Data)
    | GotWrite Write (Result String ())
    | CheckServer
    | GotServerCheck Bool
    | PromptInput String
    | SendPrompt
    | GotReply (Result Llm.Error Llm.Reply)
    | StatusTick
    | SaveShortcut
    | AskConfirm Confirmable
    | GotConfirm Bool
    | SaveActiveRecipe
    | GotSaveTime Time.Posix
    | StartFork String -- saved recipe id
    | StartEdit String -- saved recipe id
    | EditTitle String
    | EditItem RecipeList Int String
    | InsertItem RecipeList Int -- a new empty item at this index
    | RemoveItem RecipeList Int
    | SaveEdit
    | GotEditSaveTime Time.Posix
    | StartDiscard
    | Focused
    | StatusPicked ( String, Int )
    | StockInput String
    | SaveStock
    | ProviderSelected String
    | DeepSeekApiKeyInput String
    | DeepSeekModelSelected String
    | OllamaBaseUrlInput String
    | OllamaModelInput String
    | SaveSettings


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.navKey (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            routeTo (Route.fromUrl url) model

        GotTimezone timezone ->
            ( { model | timezone = timezone }, Cmd.none )

        GotHealth isServer ->
            if isServer then
                ( { model | connection = Loading, serverKnown = True }
                , Cmd.batch
                    [ Server.load GotServerData
                    , if model.serverKnown then
                        Cmd.none

                      else
                        rememberServer ()
                    ]
                )

            else if model.serverKnown then
                ( { model | connection = ServerUnreachable }, Cmd.none )

            else
                -- origins deleted before pruning on delete existed
                dropMissingForkOrigins { model | connection = Disconnected }

        GotServerData result ->
            case result of
                Ok data ->
                    dropMissingForkOrigins
                        { model
                            | connection = Connected
                            , stock = Draft.init data.stock
                            , savedRecipes = data.recipes
                        }

                Err message ->
                    ( { model | connection = LoadFailed message }, Cmd.none )

        GotWrite write result ->
            case result of
                Ok () ->
                    applyWrite write { model | pendingWrite = Nothing, serverReachable = True }

                Err message ->
                    -- check now, so the status says whether the server is gone
                    ( { model | pendingWrite = Nothing, writeError = Just ( write, message ) }
                    , Server.checkHealth GotServerCheck
                    )

        CheckServer ->
            ( model
            , if model.connection == ServerUnreachable then
                -- the startup check again, so the data loads once it's back
                Server.checkHealth GotHealth

              else
                Server.checkHealth GotServerCheck
            )

        GotServerCheck reachable ->
            ( { model | serverReachable = reachable }, Cmd.none )

        PromptInput text ->
            ( { model | prompt = text }, Cmd.none )

        SendPrompt ->
            -- the button is disabled in these cases, so this is only a guard
            if String.isEmpty (String.trim model.prompt) || isAwaiting model.requestState then
                ( model, Cmd.none )

            else
                case model.settings.saved of
                    Nothing ->
                        ( model, Cmd.none )

                    Just settings ->
                        sendPrompt settings model

        GotReply result ->
            if not (isAwaiting model.requestState) then
                -- a fork replaced the generator's recipe while this was on its way
                ( model, Cmd.none )

            else
                case result of
                    Err error ->
                        ( failRequest (Llm.errorToString error) model, Cmd.none )

                    Ok reply ->
                        if reply.finishReason == "length" then
                            -- a retry would likely be cut off too
                            ( failRequest "The reply was cut off before the recipe was complete." model
                            , Cmd.none
                            )

                        else
                            case Recipe.decodeGenerated reply.content of
                                Ok generated ->
                                    let
                                        updated =
                                            { model
                                                | requestState = Idle
                                                , activeRecipe = Just generated.recipe
                                                , assistantResponse = Just generated.response
                                            }
                                    in
                                    ( updated, persistGenerated updated )

                                Err reason ->
                                    retryOrFail reason reply.content model

        AskConfirm action ->
            ( { model | pendingConfirm = Just action }
            , askConfirm (confirmMessage model action)
            )

        GotConfirm ok ->
            case ( ok, model.pendingConfirm ) of
                ( True, Just action ) ->
                    runConfirmed action { model | pendingConfirm = Nothing }

                _ ->
                    ( { model | pendingConfirm = Nothing }, Cmd.none )

        SaveShortcut ->
            -- Cmd/Ctrl+S, from anywhere on the page: save whatever the current
            -- page saves. Each save guards against having nothing to save.
            case model.route of
                Route.Create ->
                    update SaveActiveRecipe model

                Route.Stock ->
                    update SaveStock model

                Route.Settings ->
                    update SaveSettings model

                Route.Recipe _ ->
                    update SaveEdit model

                _ ->
                    ( model, Cmd.none )

        SaveActiveRecipe ->
            -- the id and timestamps need the current time
            if model.activeRecipe /= Nothing && model.pendingWrite == Nothing then
                ( model, Task.perform GotSaveTime Time.now )

            else
                ( model, Cmd.none )

        StartFork id ->
            -- replacing a recipe or a generation in progress loses it, so ask first
            if model.activeRecipe /= Nothing || isAwaiting model.requestState then
                update (AskConfirm (ForkRecipe id)) model

            else
                forkRecipe id model

        StartEdit id ->
            case findSavedRecipe id model.savedRecipes of
                Just saved ->
                    ( { model | recipeEdit = Just { id = id, draft = Draft.init saved.recipe } }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        EditTitle title ->
            ( editRecipe (\recipe -> { recipe | title = title }) model, Cmd.none )

        EditItem list index value ->
            ( editRecipeList list
                (List.indexedMap
                    (\i item ->
                        if i == index then
                            value

                        else
                            item
                    )
                )
                model
            , Cmd.none
            )

        InsertItem list index ->
            ( editRecipeList list (\items -> List.take index items ++ "" :: List.drop index items) model
            , Task.attempt (\_ -> Focused) (Dom.focus (itemId list index))
            )

        RemoveItem list index ->
            ( editRecipeList list (\items -> List.take index items ++ List.drop (index + 1) items) model
            , Cmd.none
            )

        SaveEdit ->
            -- also reached via Cmd/Ctrl+S, so guard against a no-op save
            if Maybe.map canSaveEdit model.recipeEdit == Just True && model.pendingWrite == Nothing then
                ( model, Task.perform GotEditSaveTime Time.now )

            else
                ( model, Cmd.none )

        GotEditSaveTime now ->
            case model.recipeEdit |> Maybe.andThen (\edit -> findSavedRecipe edit.id model.savedRecipes |> Maybe.map (Tuple.pair edit)) of
                Just ( edit, saved ) ->
                    startWrite (WriteEdit { saved | recipe = cleanRecipe edit.draft.draft, updatedAt = now }) model

                Nothing ->
                    ( model, Cmd.none )

        StartDiscard ->
            -- nothing to lose without changes, so only ask when there are some
            if Maybe.map (.draft >> Draft.isDirty) model.recipeEdit == Just True then
                update (AskConfirm DiscardEdit) model

            else
                ( { model | recipeEdit = Nothing }, Cmd.none )

        Focused ->
            ( model, Cmd.none )

        GotSaveTime now ->
            case model.activeRecipe of
                Just recipe ->
                    startWrite (WriteNewRecipe (SavedRecipe.new now model.forkedFrom recipe)) model

                Nothing ->
                    ( model, Cmd.none )

        StatusTick ->
            case model.requestState of
                Awaiting awaiting ->
                    let
                        ticked =
                            { awaiting
                                | glyphIndex = awaiting.glyphIndex + 1
                                , secondsLeft = awaiting.secondsLeft - 1
                            }
                    in
                    ( { model | requestState = Awaiting ticked }
                    , if ticked.secondsLeft <= 0 then
                        Random.generate StatusPicked (nextStatus awaiting.status)

                      else
                        Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        StatusPicked ( status, seconds ) ->
            case model.requestState of
                Awaiting awaiting ->
                    ( { model | requestState = Awaiting { awaiting | status = status, secondsLeft = seconds } }
                    , Cmd.none
                    )

                _ ->
                    -- the reply arrived first
                    ( model, Cmd.none )

        StockInput text ->
            ( { model | stock = Draft.set text model.stock }, Cmd.none )

        SaveStock ->
            -- also reached via Cmd/Ctrl+S, so guard against a no-op save
            if Draft.isDirty model.stock then
                startWrite (WriteStock model.stock.draft) model

            else
                ( model, Cmd.none )

        ProviderSelected str ->
            case Settings.providerKindFromString str of
                Just kind ->
                    ( editSettings
                        (\s -> { s | provider = kind })
                        model
                    , Cmd.none
                    )

                Nothing ->
                    ( model, logError ("Unknown provider: " ++ str) )

        DeepSeekApiKeyInput apiKey ->
            ( editSettings (\s -> { s | deepSeek = setApiKey apiKey s.deepSeek }) model, Cmd.none )

        DeepSeekModelSelected id ->
            ( editSettings (\s -> { s | deepSeek = setModel id s.deepSeek }) model, Cmd.none )

        OllamaBaseUrlInput baseUrl ->
            ( editSettings (\s -> { s | ollama = setBaseUrl baseUrl s.ollama }) model, Cmd.none )

        OllamaModelInput id ->
            ( editSettings (\s -> { s | ollama = setModel id s.ollama }) model, Cmd.none )

        SaveSettings ->
            -- also reached via Cmd/Ctrl+S, so guard against a no-op save
            case settingsToSave model.settings of
                Just parsed ->
                    ( { model | settings = { saved = Just parsed, form = model.settings.form } }
                    , saveSettings (Settings.encodeForm model.settings.form)
                    )

                Nothing ->
                    ( model, Cmd.none )


{-| The parsed form, if it's valid and differs from what's saved.
-}
settingsToSave : SettingsEditor -> Maybe Settings
settingsToSave settings =
    case Settings.parse settings.form of
        Ok parsed ->
            if Just parsed /= settings.saved then
                Just parsed

            else
                Nothing

        Err _ ->
            Nothing


{-| Clears the chat box, which shows the status as its placeholder while
waiting. The prompt is kept so `failRequest` can put it back.
-}
sendPrompt : Settings -> Model -> ( Model, Cmd Msg )
sendPrompt settings model =
    let
        connection =
            Settings.connection settings

        messages =
            [ Llm.System Recipe.systemPrompt
            , Llm.User (Recipe.userMessage { stock = model.stock.saved, request = model.prompt, currentRecipe = model.activeRecipe })
            ]
    in
    ( { model
        | requestState =
            Awaiting
                { sentPrompt = model.prompt
                , status = "Generating"
                , secondsLeft = 3
                , glyphIndex = 0
                , connection = connection
                , messages = messages
                , isRetry = False
                }
        , prompt = ""
      }
    , Llm.jsonChatCompletion connection messages GotReply
    )


{-| A reply that was empty or not a valid recipe gets one corrective retry: the
conversation so far, the bad reply (if any), and a note saying what was wrong.
A second bad reply fails. The status keeps cycling throughout.
-}
retryOrFail : String -> String -> Model -> ( Model, Cmd Msg )
retryOrFail reason content model =
    case model.requestState of
        Awaiting awaiting ->
            if awaiting.isRetry then
                ( failRequest "The reply wasn't a valid recipe, even after a retry. Try sending it again." model
                , Cmd.none
                )

            else
                let
                    badReply =
                        -- providers reject an empty assistant message
                        if String.isEmpty (String.trim content) then
                            []

                        else
                            [ Llm.Assistant content ]

                    messages =
                        awaiting.messages
                            ++ badReply
                            ++ [ Llm.User (Recipe.correction reason) ]
                in
                ( { model | requestState = Awaiting { awaiting | messages = messages, isRetry = True } }
                , Llm.jsonChatCompletion awaiting.connection messages GotReply
                )

        _ ->
            ( model, Cmd.none )


{-| Shows the error and puts the sent prompt back in the chat box, so it can be
resent without retyping.
-}
failRequest : String -> Model -> Model
failRequest message model =
    case model.requestState of
        Awaiting { sentPrompt } ->
            { model | requestState = Failed message, prompt = sentPrompt }

        _ ->
            { model | requestState = Failed message }


confirmMessage : Model -> Confirmable -> String
confirmMessage model action =
    case action of
        ClearGenerator ->
            "Clear this recipe? It hasn't been saved."

        DeleteRecipe id ->
            case findSavedRecipe id model.savedRecipes of
                Just saved ->
                    "Delete “" ++ saved.recipe.title ++ "”? This can't be undone."

                Nothing ->
                    "Delete this recipe? This can't be undone."

        DiscardEdit ->
            "Discard your changes to this recipe?"

        ForkRecipe _ ->
            if isAwaiting model.requestState then
                "Fork this recipe? The recipe being generated will be discarded."

            else
                "Fork this recipe? The generator's unsaved recipe will be replaced."


runConfirmed : Confirmable -> Model -> ( Model, Cmd Msg )
runConfirmed action model =
    case action of
        ClearGenerator ->
            let
                cleared =
                    { model | activeRecipe = Nothing, assistantResponse = Nothing, forkedFrom = Nothing }
            in
            ( cleared, persistGenerated cleared )

        DeleteRecipe id ->
            startWrite (WriteDelete id) model

        ForkRecipe id ->
            forkRecipe id model

        DiscardEdit ->
            ( { model | recipeEdit = Nothing }, Cmd.none )


{-| Opens a copy of the saved recipe in the generator, to change with prompts
and save as a new recipe that records where it came from. Replaces whatever
the generator held, including a generation in progress (its reply is ignored).
-}
forkRecipe : String -> Model -> ( Model, Cmd Msg )
forkRecipe id model =
    case findSavedRecipe id model.savedRecipes of
        Just saved ->
            let
                forked =
                    { model
                        | activeRecipe = Just saved.recipe
                        , assistantResponse = Nothing
                        , forkedFrom = Just (SavedRecipe.forkOrigin saved)
                        , requestState = Idle
                    }
            in
            ( forked
            , Cmd.batch
                [ persistGenerated forked
                , Nav.pushUrl model.navKey (Route.toFragment Route.Create)
                ]
            )

        Nothing ->
            ( model, Cmd.none )


{-| Stores a change. localStorage takes it at once; the server gets one write
at a time, and the model waits for its reply (`GotWrite`).
-}
startWrite : Write -> Model -> ( Model, Cmd Msg )
startWrite write model =
    if model.pendingWrite /= Nothing then
        -- the buttons that write are disabled meanwhile, so this is only a guard
        ( model, Cmd.none )

    else
        case model.connection of
            Connected ->
                ( { model | pendingWrite = Just write, writeError = Nothing }
                , sendWrite write
                )

            Disconnected ->
                let
                    ( applied, cmd ) =
                        applyWrite write { model | writeError = Nothing }
                in
                ( applied
                , Cmd.batch
                    [ cmd
                    , case write of
                        WriteStock stock ->
                            saveStock stock

                        _ ->
                            saveRecipes (SavedRecipe.encodeList applied.savedRecipes)
                    ]
                )

            _ ->
                -- no page to save from until storage is settled, but Cmd/Ctrl+S
                -- still arrives, and the generator's recipe is already loaded
                ( model, Cmd.none )


sendWrite : Write -> Cmd Msg
sendWrite write =
    case write of
        WriteStock stock ->
            Server.putStock stock (GotWrite write)

        WriteNewRecipe saved ->
            Server.createRecipe saved (GotWrite write)

        WriteEdit saved ->
            Server.updateRecipe saved (GotWrite write)

        WriteDelete id ->
            Server.deleteRecipe id (GotWrite write)


{-| Updates the model for a stored change. On the server that's after its
reply, and the user may have carried on meanwhile, so each case checks the
page still shows what was saved before moving on from it.
-}
applyWrite : Write -> Model -> ( Model, Cmd Msg )
applyWrite write model =
    case write of
        WriteStock stock ->
            let
                current =
                    model.stock
            in
            -- the draft may have changed since, so only `saved` moves
            ( { model | stock = { current | saved = stock } }, Cmd.none )

        WriteNewRecipe saved ->
            -- Saving moves the recipe out of the generator: it's cleared, and
            -- the saved recipe's page opens. A second save arriving now finds
            -- nothing to save.
            let
                withSaved =
                    { model | savedRecipes = model.savedRecipes ++ [ saved ] }
            in
            if model.activeRecipe == Just saved.recipe then
                let
                    cleared =
                        { withSaved | activeRecipe = Nothing, assistantResponse = Nothing, forkedFrom = Nothing }
                in
                ( cleared
                , Cmd.batch
                    [ persistGenerated cleared
                    , if model.route == Route.Create then
                        Nav.pushUrl model.navKey (Route.toFragment (Route.Recipe saved.id))

                      else
                        Cmd.none
                    ]
                )

            else
                -- a new generation replaced it while it saved
                ( withSaved, Cmd.none )

        WriteEdit saved ->
            let
                savedRecipes =
                    List.map
                        (\existing ->
                            if existing.id == saved.id then
                                saved

                            else
                                existing
                        )
                        model.savedRecipes

                recipeEdit =
                    model.recipeEdit
                        |> Maybe.andThen
                            (\edit ->
                                if edit.id /= saved.id then
                                    Just edit

                                else if cleanRecipe edit.draft.draft == saved.recipe then
                                    Nothing

                                else
                                    -- edited further while it saved: keep editing
                                    Just { edit | draft = { saved = saved.recipe, draft = edit.draft.draft } }
                            )
            in
            ( { model | savedRecipes = savedRecipes, recipeEdit = recipeEdit }, Cmd.none )

        WriteDelete id ->
            let
                ( pruned, pruneCmd ) =
                    dropMissingForkOrigins
                        { model | savedRecipes = List.filter (\saved -> saved.id /= id) model.savedRecipes }
            in
            ( pruned
            , Cmd.batch
                [ pruneCmd

                -- replace, so Back doesn't return to the deleted recipe's page
                , if model.route == Route.Recipe id then
                    Nav.replaceUrl model.navKey (Route.toFragment Route.Saved)

                  else
                    Cmd.none
                ]
            )


{-| The page a write was made from, where its error shows.
-}
writePage : Write -> Route
writePage write =
    case write of
        WriteStock _ ->
            Route.Stock

        WriteNewRecipe _ ->
            Route.Create

        WriteEdit saved ->
            Route.Recipe saved.id

        WriteDelete id ->
            Route.Recipe id


{-| Forgets fork origins, saved and in the generator, whose recipe no longer
exists: a deleted recipe isn't coming back. Stores whatever changed, except
recipes on the server, which keep theirs until next saved (the page hides a
missing origin either way).
-}
dropMissingForkOrigins : Model -> ( Model, Cmd Msg )
dropMissingForkOrigins model =
    let
        exists origin =
            findSavedRecipe origin.id model.savedRecipes /= Nothing

        keepExisting forkedFrom =
            Maybe.andThen
                (\origin ->
                    if exists origin then
                        Just origin

                    else
                        Nothing
                )
                forkedFrom

        savedRecipes =
            List.map (\saved -> { saved | forkedFrom = keepExisting saved.forkedFrom }) model.savedRecipes

        pruned =
            { model | savedRecipes = savedRecipes, forkedFrom = keepExisting model.forkedFrom }
    in
    ( pruned
    , Cmd.batch
        [ if savedRecipes /= model.savedRecipes && model.connection == Disconnected then
            saveRecipes (SavedRecipe.encodeList savedRecipes)

          else
            Cmd.none
        , if pruned.forkedFrom /= model.forkedFrom then
            persistGenerated pruned

          else
            Cmd.none
        ]
    )


{-| Stores the recipe on the generator page, with the model's note and what it
was forked from, so it survives a reload. `null` when there's none.
-}
persistGenerated : Model -> Cmd Msg
persistGenerated model =
    saveGenerated
        (case model.activeRecipe of
            Just recipe ->
                E.object
                    (Recipe.encodeFields recipe
                        ++ [ ( "response", E.string (Maybe.withDefault "" model.assistantResponse) )
                           , ( "forkedFrom"
                             , Maybe.map SavedRecipe.encodeForkOrigin model.forkedFrom
                                |> Maybe.withDefault E.null
                             )
                           ]
                    )

            Nothing ->
                E.null
        )


editRecipe : (Recipe -> Recipe) -> Model -> Model
editRecipe f model =
    { model | recipeEdit = Maybe.map (\edit -> { edit | draft = Draft.edit f edit.draft }) model.recipeEdit }


editRecipeList : RecipeList -> (List String -> List String) -> Model -> Model
editRecipeList list f =
    editRecipe
        (\recipe ->
            case list of
                Ingredients ->
                    { recipe | ingredients = f recipe.ingredients }

                Steps ->
                    { recipe | steps = f recipe.steps }
        )


{-| Save is enabled while the edit has changes and a title.
-}
canSaveEdit : RecipeEdit -> Bool
canSaveEdit edit =
    Draft.isDirty edit.draft && not (String.isEmpty (String.trim edit.draft.draft.title))


{-| What Save stores: trimmed, with blank ingredients and steps dropped.
-}
cleanRecipe : Recipe -> Recipe
cleanRecipe recipe =
    let
        cleanList =
            List.map String.trim >> List.filter (not << String.isEmpty)
    in
    { title = String.trim recipe.title
    , ingredients = cleanList recipe.ingredients
    , steps = cleanList recipe.steps
    }


setApiKey : String -> { a | apiKey : String } -> { a | apiKey : String }
setApiKey apiKey section =
    { section | apiKey = apiKey }


setModel : String -> { a | model : String } -> { a | model : String }
setModel id section =
    { section | model = id }


setBaseUrl : String -> { a | baseUrl : String } -> { a | baseUrl : String }
setBaseUrl baseUrl section =
    { section | baseUrl = baseUrl }


editSettings : (Settings.Form -> Settings.Form) -> Model -> Model
editSettings f model =
    let
        settings =
            model.settings
    in
    { model | settings = { settings | form = f settings.form } }



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ saveShortcut (\_ -> SaveShortcut)
        , confirmed GotConfirm
        , if isAwaiting model.requestState then
            Time.every 1000 (\_ -> StatusTick)

          else
            Sub.none
        , case model.connection of
            Connected ->
                Time.every 15000 (\_ -> CheckServer)

            ServerUnreachable ->
                -- sooner, since there's nothing to do until it's back
                Time.every 5000 (\_ -> CheckServer)

            _ ->
                Sub.none
        ]



-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title =
        case pageName model.route of
            Just name ->
                name

            Nothing ->
                "Clerk"
    , body =
        [ viewNav model.route
        , viewMain model
        , viewConnectionStatus model
        ]
    }


{-| A bar along the bottom of the screen, only while the self-host server this
page came from can't be reached, so a save won't fail by surprise.
-}
viewConnectionStatus : Model -> Html Msg
viewConnectionStatus model =
    let
        offline =
            case model.connection of
                Connected ->
                    not model.serverReachable

                ServerUnreachable ->
                    True

                _ ->
                    False
    in
    if offline then
        div
            [ class "offline"
            , attribute "role" "status"
            , title "Can't reach the Clerk server. Changes can't be saved until it's back."
            ]
            [ text "offline" ]

    else
        text ""


viewNav : Route -> Html Msg
viewNav route =
    nav
        [ class "app-nav" ]
        [ img [ class "logo", src "icon.svg", alt "Clerk" ] []
        , div
            [ class "links" ]
            (List.map (viewNavLink route) [ Route.Create, Route.Stock, Route.Saved, Route.Settings ])
        ]


viewNavLink : Route -> Route -> Html Msg
viewNavLink current route =
    viewLink (route == current) (Maybe.withDefault "" (pageName route)) (Route.toFragment route)


{-| Shown in the nav and the browser tab title ("Recipe generator").
-}
pageName : Route -> Maybe String
pageName route =
    case route of
        Route.Create ->
            Just "Recipe generator"

        Route.Stock ->
            Just "Manage stock"

        Route.Saved ->
            Just "Saved recipes"

        Route.Recipe _ ->
            Just "Recipe details"

        Route.Settings ->
            Just "Settings"

        Route.NotFound ->
            Nothing


viewLink : Bool -> String -> String -> Html Msg
viewLink active name path =
    a
        [ href path
        , classList [ ( "active", active ) ]
        ]
        [ text name ]


viewMain : Model -> Html Msg
viewMain model =
    main_
        []
        [ case ( model.connection, model.route ) of
            ( Loading, _ ) ->
                p [] [ text "Loading…" ]

            ( ServerUnreachable, _ ) ->
                div []
                    [ h1 [] [ text "Can't reach the Clerk server" ]
                    , p [] [ text "Your stock and saved recipes are stored on it. They'll load here once it's back." ]
                    ]

            ( LoadFailed message, _ ) ->
                div []
                    [ h1 [] [ text "Couldn't load your data" ]
                    , p [ class "error" ] [ text message ]
                    , p [] [ text "Reload the page to try again." ]
                    ]

            ( _, Route.Create ) ->
                viewRecipeGenerator model

            ( _, Route.Stock ) ->
                viewManageStock model

            ( _, Route.Saved ) ->
                viewSavedRecipes model.timezone model.savedRecipes

            ( _, Route.Recipe id ) ->
                viewRecipeDetails model id

            ( _, Route.Settings ) ->
                viewSettings model.settings

            -- this is an invalid state and should never occur
            ( _, Route.NotFound ) ->
                text "internal error"
        ]


viewRecipeGenerator : Model -> Html Msg
viewRecipeGenerator model =
    let
        isConfigured =
            model.settings.saved /= Nothing
    in
    div
        [ class "recipe-generator" ]
        [ case model.activeRecipe of
            Just recipe ->
                -- The recipe's title takes the place of "Recipe generator".
                viewRecipe
                    { actions =
                        [ viewActionButton { kind = Neutral, icon = Icons.eraser, label = "Clear", msg = AskConfirm ClearGenerator } []
                        , viewSaveButton SaveActiveRecipe (model.pendingWrite == Nothing)
                        ]
                    , details = [ viewForkedFrom model.savedRecipes model.forkedFrom, viewWriteError model ]
                    }
                    recipe

            Nothing ->
                div []
                    [ h1 [] [ text "Recipe generator" ]
                    , div
                        [ class "opening-prompt" ]
                        (if isAwaiting model.requestState then
                            [ div [ class "spinner", attribute "role" "status", attribute "aria-label" "Generating recipe" ] [] ]

                         else if isConfigured then
                            [ p [ class "opening-hint" ]
                                [ text "Describe a dish or a snack. Your "
                                , a [ href (Route.toFragment Route.Stock) ] [ text "stock" ]
                                , text " is sent with your prompt automatically."
                                ]
                            ]

                         else
                            [ viewNoProvider "opening-hint error" ]
                        )
                    ]
        , case model.assistantResponse of
            Just response ->
                p [ class "assistant-response" ] [ text response ]

            Nothing ->
                text ""
        , viewChat
            { prompt = model.prompt
            , isConfigured = isConfigured
            , showNoProvider = model.activeRecipe /= Nothing -- otherwise it's in place of the opening hint
            }
            model.requestState
        ]


viewNoProvider : String -> Html Msg
viewNoProvider className =
    p [ class className ]
        [ strong [] [ text "No LLM provider" ]
        , text ": setup an LLM provider in the "
        , a [ href (Route.toFragment Route.Settings) ] [ text "Settings" ]
        ]


viewChat :
    { prompt : String
    , isConfigured : Bool
    , showNoProvider : Bool
    }
    -> RequestState
    -> Html Msg
viewChat { prompt, isConfigured, showNoProvider } requestState =
    let
        awaiting =
            isAwaiting requestState

        placeholderText =
            case requestState of
                Awaiting { status, glyphIndex } ->
                    glyphAt glyphIndex ++ " " ++ status ++ "…"

                _ ->
                    "Enter prompt"
    in
    div
        [ class "chat" ]
        [ if isConfigured || not showNoProvider then
            text ""

          else
            viewNoProvider "error"
        , case requestState of
            Failed message ->
                p [ class "error" ] [ text message ]

            _ ->
                text ""
        , div
            [ class "container" ]
            [ textarea
                [ id "chat"
                , attribute "aria-label" "Recipe prompt" -- the visible label is gone once a recipe shows
                , rows 1
                , value prompt
                , disabled (not isConfigured || awaiting)
                , onInput PromptInput
                , preventDefaultOn "keydown" enterSendsDecoder
                , placeholder placeholderText
                ]
                []
            , div
                [ class "button-container" ]
                [ button
                    [ class "send"
                    , onClick SendPrompt
                    , disabled (not isConfigured || awaiting || String.isEmpty (String.trim prompt))
                    , title "Send"
                    , attribute "aria-label" "Send"
                    ]
                    [ Icons.arrowUp ]
                ]
            ]
        ]


viewManageStock : Model -> Html Msg
viewManageStock model =
    let
        stock =
            model.stock
    in
    div
        [ class "manage-stock" ]
        [ viewHeader []
            (h1 [] [ text "Manage stock" ])
            [ viewSaveButton SaveStock (Draft.isDirty stock && model.pendingWrite == Nothing) ]
        , viewWriteError model
        , p [] [ text "Describe what's in your kitchen pantry, refrigerator, or freezer. You can even list your pots and pans here, or give the LLM extra instructions about how you like your food prepared." ]
        , textarea
            [ id "stock"
            , rows 5
            , value stock.draft
            , onInput StockInput
            , placeholder """onions, garlic, ginger
chile peppers
half dozen eggs
portabella mushrooms
"""
            ]
            []
        ]


{-| Most recently saved or edited first. Each entry shows that date (in the
user's time zone), then the title linking to the recipe's page.
-}
viewSavedRecipes : Time.Zone -> List SavedRecipe -> Html Msg
viewSavedRecipes timezone savedRecipes =
    div
        [ class "saved-recipes" ]
        [ h1 [] [ text "Saved recipes" ]
        , if List.isEmpty savedRecipes then
            section []
                [ p [] [ text "No saved recipes yet." ]
                , p []
                    [ text "Generate one in the "
                    , a [ href (Route.toFragment Route.Create) ] [ text "Recipe generator" ]
                    , text " and save it."
                    ]
                ]

          else
            ul []
                (savedRecipes
                    |> List.sortBy (.updatedAt >> Time.posixToMillis >> negate)
                    |> List.map (viewSavedRecipeItem timezone)
                )
        ]


viewSavedRecipeItem : Time.Zone -> SavedRecipe -> Html Msg
viewSavedRecipeItem timezone saved =
    li []
        [ viewDate timezone saved.updatedAt
        , text " "
        , a [ href (Route.toFragment (Route.Recipe saved.id)) ] [ text saved.recipe.title ]
        ]


{-| A saved recipe's page: the recipe, when it was saved and updated, and what
it was forked from. An unknown id (deleted, or a stale link) gets a message
rather than an error.
-}
viewRecipeDetails : Model -> String -> Html Msg
viewRecipeDetails model id =
    case findSavedRecipe id model.savedRecipes of
        Just saved ->
            let
                details =
                    [ viewDate model.timezone saved.updatedAt
                    , viewForkedFrom model.savedRecipes saved.forkedFrom
                    , viewWriteError model
                    ]

                writing =
                    model.pendingWrite /= Nothing
            in
            div
                [ class "recipe-details" ]
                [ case model.recipeEdit of
                    Just edit ->
                        if edit.id == saved.id then
                            -- Save takes Fork's place and Discard Delete's; Edit is hidden.
                            viewRecipeEditor
                                { actions =
                                    [ viewSaveButton SaveEdit (canSaveEdit edit && not writing)
                                    , viewActionButton { kind = Neutral, icon = Icons.undo, label = "Discard", msg = StartDiscard } []
                                    ]
                                , details = details
                                }
                                edit.draft.draft

                        else
                            viewSavedRecipe details writing saved

                    Nothing ->
                        viewSavedRecipe details writing saved
                ]

        Nothing ->
            div
                [ class "recipe-details" ]
                [ h1 [] [ text "Recipe not found" ]
                , p []
                    [ text "It may have been deleted. See your "
                    , a [ href (Route.toFragment Route.Saved) ] [ text "Saved recipes" ]
                    , text "."
                    ]
                ]


viewSavedRecipe : List (Html Msg) -> Bool -> SavedRecipe -> Html Msg
viewSavedRecipe details writing saved =
    viewRecipe
        { actions =
            [ viewActionButton { kind = Fork, icon = Icons.gitFork, label = "Fork", msg = StartFork saved.id } []
            , viewActionButton { kind = Neutral, icon = Icons.pencil, label = "Edit", msg = StartEdit saved.id } []
            , viewActionButton { kind = Danger, icon = Icons.trash, label = "Delete", msg = AskConfirm (DeleteRecipe saved.id) } [ disabled writing ]
            ]
        , details = details
        }
        saved.recipe


{-| Why the last save on this page failed, if it did.
-}
viewWriteError : Model -> Html Msg
viewWriteError model =
    case model.writeError of
        Just ( write, message ) ->
            if writePage write == model.route then
                p [ class "error" ] [ text ("Couldn't save: " ++ message) ]

            else
                text ""

        Nothing ->
            text ""


findSavedRecipe : String -> List SavedRecipe -> Maybe SavedRecipe
findSavedRecipe id savedRecipes =
    List.filter (\saved -> saved.id == id) savedRecipes
        |> List.head


{-| A link to the recipe it was forked from. Nothing if it wasn't forked or
the original no longer exists.
-}
viewForkedFrom : List SavedRecipe -> Maybe SavedRecipe.ForkOrigin -> Html Msg
viewForkedFrom savedRecipes forkedFrom =
    case forkedFrom |> Maybe.andThen (\origin -> findSavedRecipe origin.id savedRecipes |> Maybe.map (always origin)) of
        Just origin ->
            p [ class "recipe-meta" ]
                [ text "Forked from "
                , a [ href (Route.toFragment (Route.Recipe origin.id)) ] [ text origin.title ]
                ]

        Nothing ->
            text ""


{-| A date in the user's time zone, as `<time datetime="YYYY-MM-DD">`.
-}
viewDate : Time.Zone -> Time.Posix -> Html Msg
viewDate timezone posix =
    let
        formatted =
            TimeFormat.date timezone posix
    in
    time [ datetime formatted ] [ text formatted ]


{-| A recipe: its title in the top left and its action row in the top right
(`viewHeader` with `recipe-header`, which limits the title's width), optional
details (on a saved recipe's page, the saved date and fork origin), then
ingredients and steps.
-}
viewRecipe :
    { actions : List (Html Msg) -- the action row below the title
    , details : List (Html Msg) -- shown under the title
    }
    -> Recipe
    -> Html Msg
viewRecipe { actions, details } recipe =
    div
        []
        (viewHeader [ "recipe-header" ] (h1 [] [ text recipe.title ]) actions
            :: details
            ++ [ div
                    [ class "recipe-columns" ]
                    [ viewIngredients recipe.ingredients
                    , viewSteps recipe.steps
                    ]
               ]
        )


{-| `viewRecipe` with every part editable: the title, and each ingredient and
step, which can be removed or have a new one added below it.
-}
viewRecipeEditor :
    { actions : List (Html Msg)
    , details : List (Html Msg)
    }
    -> Recipe
    -> Html Msg
viewRecipeEditor { actions, details } recipe =
    div
        [ class "recipe-editor" ]
        (viewHeader [ "recipe-header" ]
            (h1 []
                [ input
                    [ class "title-input"
                    , attribute "aria-label" "Title"
                    , value recipe.title
                    , onInput EditTitle
                    ]
                    []
                ]
            )
            actions
            :: details
            ++ [ div
                    [ class "recipe-columns" ]
                    [ div []
                        [ h3 [] [ text "Ingredients" ]
                        , viewEditableList Ingredients ul recipe.ingredients
                        ]
                    , div []
                        [ h3 [] [ text "Steps" ]
                        , viewEditableList Steps ol recipe.steps
                        ]
                    ]
               ]
        )


viewEditableList : RecipeList -> (List (Attribute Msg) -> List (Html Msg) -> Html Msg) -> List String -> Html Msg
viewEditableList list listElement items =
    if List.isEmpty items then
        -- with no item to add below, add the first one
        button [ class "item-button add-first", onClick (InsertItem list 0) ]
            [ Icons.plus, text ("Add " ++ itemName list) ]

    else
        listElement [] (List.indexedMap (viewEditableItem list) items)


viewEditableItem : RecipeList -> Int -> String -> Html Msg
viewEditableItem list index item =
    let
        name =
            itemName list ++ " " ++ String.fromInt (index + 1)

        attributes =
            [ id (itemId list index)
            , attribute "aria-label" (String.toUpper (String.left 1 name) ++ String.dropLeft 1 name)
            , value item
            , onInput (EditItem list index)
            ]
    in
    li []
        [ div [ class "editable-item" ]
            [ case list of
                -- steps run long, so they start at three lines and grow with their text
                Steps ->
                    textarea (rows 5 :: attributes) []

                Ingredients ->
                    input attributes []
            , button
                [ class "item-button"
                , onClick (InsertItem list (index + 1))
                , title ("Add " ++ itemName list ++ " below")
                , attribute "aria-label" ("Add " ++ itemName list ++ " below " ++ name)
                ]
                [ Icons.plus ]
            , button
                [ class "item-button"
                , onClick (RemoveItem list index)
                , title ("Remove " ++ itemName list)
                , attribute "aria-label" ("Remove " ++ name)
                ]
                [ Icons.x ]
            ]
        ]


itemName : RecipeList -> String
itemName list =
    case list of
        Ingredients ->
            "ingredient"

        Steps ->
            "step"


{-| The id of an item's field, so a newly added one can be focused.
-}
itemId : RecipeList -> Int -> String
itemId list index =
    itemName list ++ "-" ++ String.fromInt index


viewIngredients : List String -> Html Msg
viewIngredients ingredients =
    div
        []
        [ h3 [] [ text "Ingredients" ]
        , ul [] (List.map viewRecipeListItem ingredients)
        ]


viewSteps : List String -> Html Msg
viewSteps steps =
    div
        []
        [ h3 [] [ text "Steps" ]
        , ol [] (List.map viewRecipeListItem steps)
        ]


viewRecipeListItem : String -> Html Msg
viewRecipeListItem item =
    li [] [ text item ]


viewSettings : SettingsEditor -> Html Msg
viewSettings settings =
    let
        form =
            settings.form
    in
    div
        [ class "settings" ]
        [ viewHeader []
            (h1 [] [ text "Settings" ])
            [ viewSaveButton SaveSettings (settingsToSave settings /= Nothing) ]
        , section []
            [ h2 [] [ text "Language model" ]
            , dl [ class "fields" ]
                (viewField "provider"
                    "Provider"
                    (select
                        [ id "provider", onInput ProviderSelected ]
                        (List.map (viewProviderOption form.provider) Settings.allProviderKinds)
                    )
                    (Ok ())
                    ++ viewProviderFields form
                )
            ]
        , viewAbout
        ]


{-| The font and icons that ship with Clerk, each with its license, and where
its source lives.
-}
viewAbout : Html Msg
viewAbout =
    section [ class "about" ]
        [ h2 [] [ text "About" ]
        , dl []
            [ dt [] [ text "Font" ]
            , dd []
                [ viewExternalLink "https://www.brailleinstitute.org/freefont/" "Atkinson Hyperlegible Next"
                , text " ("
                , viewExternalLink "https://openfontlicense.org/open-font-license-official-text/" "SIL Open Font License 1.1"
                , text ")"
                ]
            , dt [] [ text "Icons" ]
            , dd []
                [ viewExternalLink "https://lucide.dev" "Lucide"
                , text " ("
                , viewExternalLink "https://github.com/lucide-icons/lucide/blob/main/LICENSE" "ISC License"
                , text ", MIT for icons from Feather)"
                ]
            , dt [] [ text "Source" ]
            , dd []
                [ viewExternalLink "https://git.cowell.dev/clerk" "git.cowell.dev/clerk"
                , text " ("
                , viewExternalLink "https://github.com/cowellmi/clerk" "GitHub mirror"
                , text ")"
                ]
            ]
        ]


{-| Opens in a new tab, so an installed app keeps its own window. The `target`
also keeps `Browser.application` from routing the click.
-}
viewExternalLink : String -> String -> Html Msg
viewExternalLink url label =
    a [ href url, target "_blank", rel "noopener" ] [ text label ]


{-| The selected provider's own fields, one row each. DeepSeek's base URL is
fixed, so it isn't shown.
-}
viewProviderFields : Settings.Form -> List (Html Msg)
viewProviderFields form =
    List.concat <|
        case form.provider of
            Settings.DeepSeekKind ->
                [ viewApiKeyField DeepSeekApiKeyInput form.deepSeek.apiKey
                , viewModelSelect DeepSeekModelSelected Settings.deepSeekModels form.deepSeek.model
                ]

            Settings.OllamaKind ->
                [ viewField "base-url"
                    "Base URL"
                    (input
                        [ id "base-url"
                        , type_ "url"
                        , placeholder Settings.ollamaDefaultBaseUrl
                        , value form.ollama.baseUrl
                        , onInput OllamaBaseUrlInput
                        ]
                        []
                    )
                    (Settings.parseBaseUrl form.ollama.baseUrl)
                , viewField "model"
                    "Model"
                    (input
                        [ id "model"
                        , placeholder "llama3.2"
                        , value form.ollama.model
                        , onInput OllamaModelInput
                        ]
                        []
                    )
                    (Settings.parseModelName form.ollama.model)
                ]


viewApiKeyField : (String -> Msg) -> String -> List (Html Msg)
viewApiKeyField toMsg apiKey =
    viewField "api-key"
        "API key"
        (input
            [ id "api-key"
            , type_ "password"
            , autocomplete False
            , value apiKey
            , onInput toMsg
            ]
            []
        )
        (Settings.parseApiKey apiKey)


viewModelSelect : (String -> Msg) -> List Settings.ModelOption -> String -> List (Html Msg)
viewModelSelect toMsg options current =
    viewField "model"
        "Model"
        (select
            [ id "model", onInput toMsg ]
            (List.map
                (\option ->
                    Html.option
                        [ value option.id, selected (option.id == current) ]
                        [ text option.label ]
                )
                options
            )
        )
        (Settings.parseListedModel options current)


{-| One settings row of a `dl.fields`: the label as the term, then the control
and its parse error if any.
-}
viewField : String -> String -> Html Msg -> Result String a -> List (Html Msg)
viewField controlId labelText control parsed =
    [ dt [] [ Html.label [ for controlId ] [ text labelText ] ]
    , dd [] (control :: viewFieldError parsed)
    ]


viewFieldError : Result String a -> List (Html Msg)
viewFieldError result =
    case result of
        Err message ->
            [ text " ", span [ class "error" ] [ text message ] ]

        Ok _ ->
            []


viewProviderOption : Settings.ProviderKind -> Settings.ProviderKind -> Html Msg
viewProviderOption current kind =
    option
        [ value (Settings.providerKindToString kind)
        , selected (kind == current)
        ]
        [ text (Settings.providerKindLabel kind) ]


{-| A heading with its action buttons on the same line: heading top-left,
buttons top-right, the same on every page. Extra classes vary it:
`recipe-header` limits a recipe title's width.
-}
viewHeader : List String -> Html Msg -> List (Html Msg) -> Html Msg
viewHeader extraClasses heading actions =
    header
        [ class (String.join " " ("with-action-buttons" :: extraClasses)) ]
        [ heading
        , div [ class "action-row" ] actions
        ]


viewSaveButton : Msg -> Bool -> Html Msg
viewSaveButton msg enabled =
    viewActionButton { kind = Primary, icon = Icons.save, label = "Save", msg = msg }
        [ tabindex 1, disabled (not enabled) ]


{-| Picks an action button's colors.
-}
type ButtonKind
    = Primary -- green: Save
    | Neutral -- grey: Clear
    | Danger -- red: Delete
    | Fork -- GitHub's green: Fork


{-| An icon-and-label button.
-}
viewActionButton : { kind : ButtonKind, icon : Html Msg, label : String, msg : Msg } -> List (Attribute Msg) -> Html Msg
viewActionButton { kind, icon, label, msg } attributes =
    let
        kindClass =
            case kind of
                Primary ->
                    "primary"

                Neutral ->
                    "neutral"

                Danger ->
                    "danger"

                Fork ->
                    "fork"
    in
    button
        ([ class ("action-button " ++ kindClass), onClick msg ] ++ attributes)
        [ icon, text label ]


{-| Enter sends the prompt; Shift+Enter inserts a newline as usual. Enter while
an IME is composing (e.g. confirming Japanese or Chinese input) is left alone:
Safari reports that as `keyCode` 229 with `isComposing` false.
-}
enterSendsDecoder : D.Decoder ( Msg, Bool )
enterSendsDecoder =
    D.map4
        (\key shift composing keyCode ->
            key == "Enter" && not shift && not composing && keyCode /= 229
        )
        (D.field "key" D.string)
        (D.field "shiftKey" D.bool)
        (D.oneOf [ D.field "isComposing" D.bool, D.succeed False ])
        (D.oneOf [ D.field "keyCode" D.int, D.succeed 0 ])
        |> D.andThen
            (\sends ->
                if sends then
                    D.succeed ( SendPrompt, True )

                else
                    D.fail "not a plain Enter"
            )



-- PORTS


port saveStock : String -> Cmd msg


port saveSettings : E.Value -> Cmd msg


port logError : String -> Cmd msg


port saveRecipes : E.Value -> Cmd msg


port saveGenerated : E.Value -> Cmd msg


{-| Notes that this browser has loaded data from the self-host server, so the
next startup that can't reach it waits for it instead of using localStorage.
-}
port rememberServer : () -> Cmd msg


{-| Cmd/Ctrl+S anywhere on the page. `init.js` listens on the document, since an
Elm subscription can't stop the browser's own "Save page" dialog.
-}
port saveShortcut : (() -> msg) -> Sub msg


{-| Shows the browser's confirm dialog with this message. The answer comes back
on `confirmed`.
-}
port askConfirm : String -> Cmd msg


port confirmed : (Bool -> msg) -> Sub msg



-- FLAGS


type alias Flags =
    { stock : String
    , settings : Settings.Form
    , recipes : List SavedRecipe
    , generated : Maybe Recipe.Generated
    , forkedFrom : Maybe SavedRecipe.ForkOrigin -- the generated recipe's
    , serverKnown : Bool
    }


flagsDecoder : D.Decoder Flags
flagsDecoder =
    D.map6 Flags
        (D.field "stock" (D.nullable D.string)
            |> D.map (Maybe.withDefault "")
        )
        (D.field "settings" (D.nullable Settings.formDecoder)
            |> D.map (Maybe.withDefault Settings.emptyForm)
        )
        (D.field "recipes" (D.nullable SavedRecipe.listDecoder)
            |> D.map (Maybe.withDefault [])
        )
        -- lenient: a stored recipe that doesn't decode just means an empty
        -- generator page
        (D.maybe (D.field "generated" Recipe.generatedDecoder))
        (D.maybe (D.at [ "generated", "forkedFrom" ] SavedRecipe.forkOriginDecoder))
        (D.field "serverKnown" D.bool)
