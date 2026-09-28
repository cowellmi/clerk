module Server exposing (Data, checkHealth, createRecipe, deleteRecipe, load, putStock, updateRecipe)

{-| The self-host server's storage API (`cmd/clerk`). URLs are
document-relative, so the app works wherever the server mounts it. Errors are
strings ready to show: the server's own message when it sends one.
-}

import Http
import Json.Decode as D
import SavedRecipe exposing (SavedRecipe)
import Task


{-| Whether the Clerk server is serving this page. A static host may answer
any path with its index page and a 200, so the body has to say it's Clerk. A
short timeout, so the app doesn't wait long on a host with no server.
-}
checkHealth : (Bool -> msg) -> Cmd msg
checkHealth toMsg =
    Http.request
        { method = "GET"
        , headers = []
        , url = "api/health"
        , body = Http.emptyBody
        , expect =
            Http.expectJson (Result.map ((==) "clerk") >> Result.withDefault False >> toMsg)
                (D.field "app" D.string)
        , timeout = Just 3000
        , tracker = Nothing
        }


{-| What the app loads at startup, as it would from localStorage.
-}
type alias Data =
    { stock : String
    , recipes : List SavedRecipe
    }


load : (Result String Data -> msg) -> Cmd msg
load toMsg =
    Task.map2 Data
        (Http.task
            { method = "GET"
            , headers = []
            , url = "api/stock"
            , body = Http.emptyBody
            , resolver = Http.stringResolver (resolve Ok)
            , timeout = Nothing
            }
        )
        (Http.task
            { method = "GET"
            , headers = []
            , url = "api/recipes"
            , body = Http.emptyBody
            , resolver = Http.stringResolver (resolve (D.decodeString SavedRecipe.listDecoder >> Result.mapError D.errorToString))
            , timeout = Nothing
            }
        )
        |> Task.attempt toMsg


putStock : String -> (Result String () -> msg) -> Cmd msg
putStock stock =
    send "PUT" "api/stock" (Http.stringBody "text/plain; charset=utf-8" stock)


{-| The id comes from the recipe (`SavedRecipe.new`), as in localStorage.
-}
createRecipe : SavedRecipe -> (Result String () -> msg) -> Cmd msg
createRecipe saved =
    send "POST" "api/recipes" (Http.jsonBody (SavedRecipe.encode saved))


updateRecipe : SavedRecipe -> (Result String () -> msg) -> Cmd msg
updateRecipe saved =
    send "PUT" (recipeUrl saved.id) (Http.jsonBody (SavedRecipe.encode saved))


deleteRecipe : String -> (Result String () -> msg) -> Cmd msg
deleteRecipe id =
    send "DELETE" (recipeUrl id) Http.emptyBody


recipeUrl : String -> String
recipeUrl id =
    -- ids are [0-9a-zT-] only, so they need no escaping
    "api/recipes/" ++ id


{-| A write, whose reply body doesn't matter.
-}
send : String -> String -> Http.Body -> (Result String () -> msg) -> Cmd msg
send method url body toMsg =
    Http.request
        { method = method
        , headers = []
        , url = url
        , body = body
        , expect = Http.expectStringResponse toMsg (resolve (\_ -> Ok ()))
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Keeps the server's message on an error status: it sends plain text.
-}
resolve : (String -> Result String a) -> Http.Response String -> Result String a
resolve onSuccess response =
    case response of
        Http.GoodStatus_ _ body ->
            onSuccess body
                |> Result.mapError (\err -> "The server's reply didn't make sense: " ++ err)

        Http.BadStatus_ metadata body ->
            Err
                ("The server returned an error (HTTP "
                    ++ String.fromInt metadata.statusCode
                    ++ ")"
                    ++ (case String.trim body of
                            "" ->
                                "."

                            message ->
                                ": " ++ message
                       )
                )

        Http.Timeout_ ->
            Err "The server took too long to answer."

        Http.NetworkError_ ->
            Err "Couldn't reach the server. Check that it's running and that you're on its network."

        Http.BadUrl_ url ->
            Err ("Invalid request URL: " ++ url)
