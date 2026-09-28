module Settings exposing
    ( ApiKey
    , DeepSeekForm
    , Form
    , Model
    , ModelOption
    , OllamaForm
    , Provider(..)
    , ProviderKind(..)
    , Settings
    , allProviderKinds
    , connection
    , deepSeekModels
    , emptyForm
    , encodeForm
    , formDecoder
    , ollamaDefaultBaseUrl
    , parse
    , parseApiKey
    , parseBaseUrl
    , parseListedModel
    , parseModelName
    , providerKindFromString
    , providerKindLabel
    , providerKindToString
    )

import Json.Decode as D
import Json.Encode as E
import Llm
import Url exposing (Url)



-- TYPES


{-| Each provider carries exactly the connection details it needs.
-}
type Provider
    = DeepSeek { apiKey : ApiKey, model : Model } -- fixed base URL
    | Ollama { baseUrl : Url, model : Model } -- self-hosted, no key


{-| Which provider is selected, before its details are parsed.
-}
type ProviderKind
    = DeepSeekKind
    | OllamaKind


{-| Never blank: only `parseApiKey` builds one.
-}
type ApiKey
    = ApiKey String


{-| A model ID the provider accepts: one of its listed models, or for Ollama any
non-blank name. Only `parseListedModel` and `parseModelName` build one.
-}
type Model
    = Model String


type alias ModelOption =
    { id : String
    , label : String
    }


{-| Parsed, usable settings. Only `parse` produces these.
-}
type alias Settings =
    { provider : Provider
    }


{-| The settings form, as typed. Turn it into `Settings` with `parse`.

Each provider has its own section, so one provider's values (a key, a URL)
never carry over to another, and switching back and forth doesn't lose what was
typed.

-}
type alias Form =
    { provider : ProviderKind
    , deepSeek : DeepSeekForm
    , ollama : OllamaForm
    }


type alias DeepSeekForm =
    { apiKey : String
    , model : String
    }


type alias OllamaForm =
    { baseUrl : String
    , model : String
    }



-- CONSTANTS


emptyForm : Form
emptyForm =
    { provider = DeepSeekKind
    , deepSeek = { apiKey = "", model = defaultModelId deepSeekModels }
    , ollama = { baseUrl = ollamaDefaultBaseUrl, model = "" }
    }


deepSeekBaseUrl : String
deepSeekBaseUrl =
    "https://api.deepseek.com"


{-| Ollama's OpenAI-compatible API on its default local port.
-}
ollamaDefaultBaseUrl : String
ollamaDefaultBaseUrl =
    "http://localhost:11434/v1"


{-| Offered in the Model dropdown; the first is the default. Checked against
DeepSeek's docs on 2026-09-23 (`deepseek-chat` is gone).
-}
deepSeekModels : List ModelOption
deepSeekModels =
    [ { id = "deepseek-flash", label = "DeepSeek Flash" }
    , { id = "deepseek-v4-pro", label = "DeepSeek V4 Pro" }
    ]


{-| The providers offered in the UI.
-}
allProviderKinds : List ProviderKind
allProviderKinds =
    [ DeepSeekKind, OllamaKind ]



-- PARSING


parse : Form -> Result String Settings
parse form =
    parseProvider form
        |> Result.map (\provider -> { provider = provider })


parseProvider : Form -> Result String Provider
parseProvider form =
    case form.provider of
        DeepSeekKind ->
            Result.map2 (\key m -> DeepSeek { apiKey = key, model = m })
                (parseApiKey form.deepSeek.apiKey)
                (parseListedModel deepSeekModels form.deepSeek.model)

        OllamaKind ->
            Result.map2 (\url m -> Ollama { baseUrl = url, model = m })
                (parseBaseUrl form.ollama.baseUrl)
                (parseModelName form.ollama.model)



-- BASE URL


parseBaseUrl : String -> Result String Url
parseBaseUrl raw =
    case String.trim raw of
        "" ->
            Err "required"

        trimmed ->
            Url.fromString trimmed
                |> Result.fromMaybe "invalid URL"


{-| How to reach the selected provider over the OpenAI chat-completions API,
which every provider speaks.
-}
connection : Settings -> Llm.Connection
connection settings =
    case settings.provider of
        DeepSeek c ->
            { chatCompletionsUrl = deepSeekBaseUrl ++ "/chat/completions"
            , apiKey = Just (apiKeyToString c.apiKey)
            , model = modelToString c.model
            }

        Ollama c ->
            { chatCompletionsUrl = urlToString c.baseUrl ++ "/chat/completions"
            , apiKey = Nothing
            , model = modelToString c.model
            }


{-| Without trailing slashes, ready to have a path appended.
-}
urlToString : Url -> String
urlToString url =
    trimTrailingSlashes (Url.toString url)


trimTrailingSlashes : String -> String
trimTrailingSlashes str =
    if String.endsWith "/" str then
        trimTrailingSlashes (String.dropRight 1 str)

    else
        str



-- API KEY


parseApiKey : String -> Result String ApiKey
parseApiKey raw =
    case String.trim raw of
        "" ->
            Err "required"

        trimmed ->
            Ok (ApiKey trimmed)


apiKeyToString : ApiKey -> String
apiKeyToString (ApiKey key) =
    key



-- MODEL


parseListedModel : List ModelOption -> String -> Result String Model
parseListedModel options id =
    if List.any (\option -> option.id == id) options then
        Ok (Model id)

    else
        Err "unknown model"


{-| For providers where any model the user has can be named (Ollama).
-}
parseModelName : String -> Result String Model
parseModelName raw =
    case String.trim raw of
        "" ->
            Err "required"

        trimmed ->
            Ok (Model trimmed)


modelToString : Model -> String
modelToString (Model id) =
    id


defaultModelId : List ModelOption -> String
defaultModelId options =
    List.head options
        |> Maybe.map .id
        |> Maybe.withDefault ""



-- PROVIDER KIND


providerKindFromString : String -> Maybe ProviderKind
providerKindFromString str =
    List.filter (\kind -> providerKindToString kind == str) allProviderKinds
        |> List.head


{-| Stable identifier, used for storage and `<option>` values.
-}
providerKindToString : ProviderKind -> String
providerKindToString kind =
    case kind of
        DeepSeekKind ->
            "deepseek"

        OllamaKind ->
            "ollama"


providerKindLabel : ProviderKind -> String
providerKindLabel kind =
    case kind of
        DeepSeekKind ->
            "DeepSeek"

        OllamaKind ->
            "Ollama"



-- JSON


{-| Lenient: a missing or invalid field falls back to its `emptyForm` value, so
one bad field (or a field added in a later version) doesn't reset the rest.
-}
formDecoder : D.Decoder Form
formDecoder =
    D.map3 Form
        (fieldOr "provider" providerKindDecoder emptyForm.provider)
        (fieldOr "deepSeek"
            (D.map2 DeepSeekForm
                (fieldOr "apiKey" D.string emptyForm.deepSeek.apiKey)
                (fieldOr "model" (listedModelDecoder deepSeekModels) emptyForm.deepSeek.model)
            )
            emptyForm.deepSeek
        )
        (fieldOr "ollama"
            (D.map2 OllamaForm
                (fieldOr "baseUrl" D.string emptyForm.ollama.baseUrl)
                (fieldOr "model" D.string emptyForm.ollama.model)
            )
            emptyForm.ollama
        )


{-| The whole form is stored, so every provider's section survives a reload,
not just the selected one. It's read back through `formDecoder` then `parse`.
-}
encodeForm : Form -> E.Value
encodeForm form =
    E.object
        [ ( "provider", E.string (providerKindToString form.provider) )
        , ( "deepSeek"
          , E.object
                [ ( "apiKey", E.string form.deepSeek.apiKey )
                , ( "model", E.string form.deepSeek.model )
                ]
          )
        , ( "ollama"
          , E.object
                [ ( "baseUrl", E.string form.ollama.baseUrl )
                , ( "model", E.string form.ollama.model )
                ]
          )
        ]


providerKindDecoder : D.Decoder ProviderKind
providerKindDecoder =
    D.string
        |> D.andThen
            (\str ->
                case providerKindFromString str of
                    Just kind ->
                        D.succeed kind

                    Nothing ->
                        D.fail ("unknown provider: " ++ str)
            )


{-| Fails on a model that's no longer listed, so `fieldOr` falls back to the
default rather than leaving the dropdown on a model it can't show.
-}
listedModelDecoder : List ModelOption -> D.Decoder String
listedModelDecoder options =
    D.string
        |> D.andThen
            (\id ->
                case parseListedModel options id of
                    Ok _ ->
                        D.succeed id

                    Err message ->
                        D.fail message
            )


fieldOr : String -> D.Decoder a -> a -> D.Decoder a
fieldOr name fieldDecoder fallback =
    D.oneOf [ D.field name fieldDecoder, D.succeed fallback ]
