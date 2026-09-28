module Llm exposing (Connection, Error(..), Message(..), Reply, errorToString, jsonChatCompletion)

{-| The OpenAI chat-completions API, which DeepSeek and Ollama (`/v1`) also
speak. Knows nothing about which provider it's talking to.
-}

import Http
import Json.Decode as D
import Json.Encode as E


type alias Connection =
    { chatCompletionsUrl : String
    , apiKey : Maybe String -- sent as a Bearer token when present
    , model : String
    }


type Message
    = System String
    | User String
    | Assistant String


type alias Reply =
    { content : String -- "" when the provider returns null
    , finishReason : String -- e.g. "stop", or "length" when truncated
    }


type Error
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus Int (Maybe String) -- the provider's error message, if it sent one
    | BadEnvelope String


{-| One non-streaming completion in JSON mode: the reply's content is a single
JSON object (valid syntax, not a guaranteed shape).
-}
jsonChatCompletion : Connection -> List Message -> (Result Error Reply -> msg) -> Cmd msg
jsonChatCompletion connection messages toMsg =
    Http.request
        { method = "POST"
        , headers =
            -- only `authorization` (plus the body's `content-type`): anything
            -- custom would fail DeepSeek's CORS preflight
            case connection.apiKey of
                Just key ->
                    [ Http.header "Authorization" ("Bearer " ++ key) ]

                Nothing ->
                    []
        , url = connection.chatCompletionsUrl
        , body = Http.jsonBody (encodeRequest connection.model messages)
        , expect = Http.expectStringResponse toMsg handleResponse
        , timeout = Nothing
        , tracker = Nothing
        }


errorToString : Error -> String
errorToString error =
    case error of
        BadUrl url ->
            "Invalid request URL: " ++ url

        Timeout ->
            "The request timed out."

        NetworkError ->
            "Couldn't reach the provider. Check your connection, the base URL, and that the provider allows requests from this site (CORS)."

        BadStatus status message ->
            "The provider returned an error (HTTP "
                ++ String.fromInt status
                ++ ")"
                ++ (case message of
                        Just m ->
                            ": " ++ m

                        Nothing ->
                            "."
                   )

        BadEnvelope details ->
            "Unexpected response from the provider: " ++ details


encodeRequest : String -> List Message -> E.Value
encodeRequest model messages =
    E.object
        [ ( "model", E.string model )
        , ( "messages", E.list encodeMessage messages )
        , ( "response_format", E.object [ ( "type", E.string "json_object" ) ] )
        , ( "max_tokens", E.int 4000 )
        , ( "stream", E.bool False )
        ]


encodeMessage : Message -> E.Value
encodeMessage message =
    let
        ( role, content ) =
            case message of
                System text ->
                    ( "system", text )

                User text ->
                    ( "user", text )

                Assistant text ->
                    ( "assistant", text )
    in
    E.object
        [ ( "role", E.string role )
        , ( "content", E.string content )
        ]


handleResponse : Http.Response String -> Result Error Reply
handleResponse response =
    case response of
        Http.BadUrl_ url ->
            Err (BadUrl url)

        Http.Timeout_ ->
            Err Timeout

        Http.NetworkError_ ->
            Err NetworkError

        Http.BadStatus_ metadata body ->
            Err (BadStatus metadata.statusCode (errorMessage body))

        Http.GoodStatus_ _ body ->
            D.decodeString replyDecoder body
                |> Result.mapError (D.errorToString >> BadEnvelope)


replyDecoder : D.Decoder Reply
replyDecoder =
    D.field "choices"
        (D.index 0
            (D.map2 Reply
                (D.at [ "message", "content" ] (D.nullable D.string) |> D.map (Maybe.withDefault ""))
                (D.field "finish_reason" (D.nullable D.string) |> D.map (Maybe.withDefault ""))
            )
        )


{-| The provider's explanation of an error status: JSON if it sent JSON, else
short plain text (DeepSeek's 401 is `Authentication Fails (governor)`).
-}
errorMessage : String -> Maybe String
errorMessage body =
    case D.decodeString errorMessageDecoder body of
        Ok message ->
            Just message

        Err _ ->
            case String.trim body of
                "" ->
                    Nothing

                trimmed ->
                    if String.length trimmed <= 300 then
                        Just trimmed

                    else
                        Nothing


{-| OpenAI-style `{"error": {"message": ...}}`, or Ollama's `{"error": "..."}`.
-}
errorMessageDecoder : D.Decoder String
errorMessageDecoder =
    D.oneOf
        [ D.at [ "error", "message" ] D.string
        , D.field "error" D.string
        ]
