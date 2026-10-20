module SavedRecipe exposing (SavedRecipe, encode, encodeList, listDecoder, new, slug)

{-| A recipe the user saved, as stored in localStorage (`clerk.recipes`).
-}

import Json.Decode as D
import Json.Encode as E
import Recipe exposing (Recipe)
import Time
import TimeFormat


type alias SavedRecipe =
    { id : String -- "{datetime}-{slug(title)}", e.g. "2026-09-16T14-05-33-chicken-and-rice-bowl"
    , recipe : Recipe
    , createdAt : Time.Posix
    , updatedAt : Time.Posix
    }


{-| A newly saved recipe.
-}
new : Time.Posix -> Recipe -> SavedRecipe
new now recipe =
    { id = TimeFormat.sortableUtc now ++ "-" ++ slug recipe.title
    , recipe = recipe
    , createdAt = now
    , updatedAt = now
    }


{-| Lowercase, with each run of characters other than a-z and 0-9 collapsed to
one `-`, and no `-` at either end. An empty result becomes `untitled`.
-}
slug : String -> String
slug title =
    let
        dashed =
            title
                |> String.toLower
                |> String.toList
                |> List.foldr
                    (\c acc ->
                        if Char.isAlphaNum c then
                            c :: acc

                        else if List.head acc == Just '-' then
                            acc

                        else
                            '-' :: acc
                    )
                    []
                |> String.fromList
                |> trimDashes
    in
    if String.isEmpty dashed then
        "untitled"

    else
        dashed


trimDashes : String -> String
trimDashes str =
    if String.startsWith "-" str then
        trimDashes (String.dropLeft 1 str)

    else if String.endsWith "-" str then
        trimDashes (String.dropRight 1 str)

    else
        str



-- JSON


{-| Lenient: a recipe that doesn't decode is dropped rather than losing the
whole list.
-}
listDecoder : D.Decoder (List SavedRecipe)
listDecoder =
    D.list (D.maybe decoder)
        |> D.map (List.filterMap identity)


{-| Flat, one object per recipe: `id`, `title`, `ingredients`, `steps`,
and `createdAt` and `updatedAt` (Unix milliseconds). The same shape as a
Connected-mode recipe file.
-}
encodeList : List SavedRecipe -> E.Value
encodeList =
    E.list encode


decoder : D.Decoder SavedRecipe
decoder =
    D.map4 SavedRecipe
        (D.field "id" D.string)
        Recipe.decoder
        (D.field "createdAt" (D.map Time.millisToPosix D.int))
        (D.field "updatedAt" (D.map Time.millisToPosix D.int))


encode : SavedRecipe -> E.Value
encode saved =
    E.object
        (( "id", E.string saved.id )
            :: Recipe.encodeFields saved.recipe
            ++ [ ( "createdAt", E.int (Time.posixToMillis saved.createdAt) )
               , ( "updatedAt", E.int (Time.posixToMillis saved.updatedAt) )
               ]
        )
