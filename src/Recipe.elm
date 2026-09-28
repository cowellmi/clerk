module Recipe exposing (Generated, Recipe, correction, decodeGenerated, decoder, encodeFields, generatedDecoder, systemPrompt, userMessage)

{-| A recipe, and how to ask an LLM for one.
-}

import Json.Decode as D
import Json.Encode as E


type alias Recipe =
    { title : String
    , ingredients : List String
    , steps : List String
    }


{-| One generation's reply: the recipe, plus the model's note to the user about
it. The note is chat about this generation, not part of the recipe, so it isn't
saved with it.
-}
type alias Generated =
    { recipe : Recipe
    , response : String
    }



-- PROMPT


instructions : String
instructions =
    "You are a practical home cook. Suggest recipes that use what's in stock and need few extra ingredients. Keep steps clear and concrete, with times and temperatures. When the request is a change to an existing recipe (or one that is currently being developed), change only what is asked for and keep everything else exactly as it was."


{-| JSON mode needs the word "json" and an example of the shape. The example
uses real values (placeholders like "List of ingredients" leak into output) and
follows its own rules, since models copy examples closely. Keep it in step with
`generatedDecoder`.
-}
outputFormat : String
outputFormat =
    String.join "\n"
        [ "Reply with a single json object and nothing else: no code fences, no text before or after it. Use exactly these keys, in this order:"
        , "- \"title\": a short recipe name."
        , "- \"ingredients\": an array of strings, one ingredient each, with its quantity."
        , "- \"steps\": an array of strings, one step each, in order, without numbering."
        , "- \"response\": 2-5 sentences of plain text (no markdown) to the user about this recipe: what you made or changed, and anything they should know, such as substitutions or ingredients not in their stock."
        , ""
        , "Example:"
        , "{\"title\": \"Garlic Butter Chicken and Rice\", \"ingredients\": [\"2 chicken thighs\", \"1 cup jasmine rice\", \"3 cloves garlic, minced\", \"2 tbsp butter\", \"Salt and black pepper, to taste\"], \"steps\": [\"Rinse the rice, then simmer it covered in 1.5 cups water for 15 minutes.\", \"Season the chicken with salt and pepper.\", \"Sear the chicken in 1 tbsp butter over medium-high heat, 5-6 minutes per side, until cooked through.\", \"Lower the heat, add the remaining butter and the garlic, and cook for 1 minute, spooning the butter over the chicken.\", \"Slice the chicken and serve it over the rice with the pan butter.\"], \"response\": \"This uses the chicken and rice from your stock, with a quick garlic butter pan sauce. Thighs stay juicier than breasts here, but breasts work if you cut the cook time by a couple of minutes. You'll need butter, which wasn't on your stock list.\"}"
        ]


{-| The cooking instructions, then the output format. Self-hosters can change
the instructions; users add their own to their stock instead (the stock page
says so). Keep format rules out of `instructions`.
-}
systemPrompt : String
systemPrompt =
    instructions ++ "\n\n" ++ outputFormat


{-| The stock as context, then the current recipe (when there is one), then the
request last, where the model weighs it most.
-}
userMessage : { stock : String, request : String, currentRecipe : Maybe Recipe } -> String
userMessage { stock, request, currentRecipe } =
    let
        stockText =
            case String.trim stock of
                "" ->
                    "(nothing listed)"

                trimmed ->
                    trimmed

        currentRecipeText =
            case currentRecipe of
                Nothing ->
                    ""

                Just recipe ->
                    "\n\nCurrent recipe (keep everything you don't explicitly change):\n"
                        ++ String.join "\n"
                            (List.filterMap identity
                                [ Just ("Title: " ++ recipe.title)
                                , nonEmptySection "Ingredients" recipe.ingredients
                                , nonEmptySection "Steps" recipe.steps
                                ]
                            )
    in
    "What I have in stock:\n" ++ stockText ++ currentRecipeText ++ "\n\nRequest:\n" ++ String.trim request


{-| Sent after a reply that couldn't be used (`decodeGenerated`'s reason), for
the one corrective retry.
-}
correction : String -> String
correction reason =
    "Your last reply couldn't be used: "
        ++ reason
        ++ ". Reply again with only the json object in the format described above: no code fences, no text before or after it."


{-| Omits the section entirely when the list is empty, rather than sending a
label with nothing under it.
-}
nonEmptySection : String -> List String -> Maybe String
nonEmptySection label items =
    case items of
        [] ->
            Nothing

        _ ->
            Just (label ++ ":\n" ++ String.join "\n" (List.map (\item -> "- " ++ item) items))



-- JSON


{-| A reply's content, decoded. Code fences around it are stripped first, since
models add them despite being told not to. On failure, the reason is phrased
for `correction`.
-}
decodeGenerated : String -> Result String Generated
decodeGenerated content =
    case stripCodeFences content of
        "" ->
            Err "it was empty"

        json ->
            D.decodeString generatedDecoder json
                |> Result.mapError
                    (\_ -> "it wasn't a single json object with exactly the keys title, ingredients, steps and response")


generatedDecoder : D.Decoder Generated
generatedDecoder =
    D.map2 Generated
        decoder
        (D.field "response" D.string)


decoder : D.Decoder Recipe
decoder =
    D.map3 Recipe
        (D.field "title" D.string)
        (D.field "ingredients" (D.list D.string))
        (D.field "steps" (D.list D.string))


{-| `title`, `ingredients` and `steps`, the fields `decoder` reads. Returned as
a list so callers can add their own fields to the same object.
-}
encodeFields : Recipe -> List ( String, E.Value )
encodeFields recipe =
    [ ( "title", E.string recipe.title )
    , ( "ingredients", E.list E.string recipe.ingredients )
    , ( "steps", E.list E.string recipe.steps )
    ]


{-| Removes a code fence around the reply: three backticks and an optional
language tag (like json) before it, and three backticks after it, on their own
lines or all on one line. Anything else is only trimmed.
-}
stripCodeFences : String -> String
stripCodeFences content =
    let
        trimmed =
            String.trim content

        fence =
            "```"
    in
    if String.startsWith fence trimmed then
        let
            inner =
                trimmed
                    |> String.dropLeft 3
                    |> dropLanguageTag
                    |> String.trim
        in
        if String.endsWith fence inner then
            String.dropRight 3 inner |> String.trim

        else
            inner

    else
        trimmed


{-| The leading letters of a fence's language tag, up to the first non-letter.
-}
dropLanguageTag : String -> String
dropLanguageTag str =
    case String.uncons str of
        Just ( c, rest ) ->
            if Char.isAlpha c then
                dropLanguageTag rest

            else
                str

        Nothing ->
            str
