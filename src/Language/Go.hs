{-# LANGUAGE DataKinds, GADTs #-}
module Language.Go where

import Prologue
import Info
import Source
import Term
import qualified Syntax as S
import Data.Record
import Range (unionRangesFrom)
import SourceSpan (unionSourceSpansFrom)

termAssignment
  :: Source Char -- ^ The source of the term.
  -> Record '[Range, Category, SourceSpan] -- ^ The proposed annotation for the term.
  -> [ SyntaxTerm Text '[Range, Category, SourceSpan] ] -- ^ The child nodes of the term.
  -> Maybe (SyntaxTerm Text '[Range, Category, SourceSpan]) -- ^ The resulting term, in IO.
termAssignment source (range :. category :. sourceSpan :. Nil) children = Just $ case (category, children) of
  (Return, _) -> withDefaultInfo $ S.Return children
  (Module, _) -> case Prologue.break (\node -> Info.category (extract node) == Other "package_clause") children of
    (comments, packageName : rest) -> case unwrap packageName of
        S.Indexed [id] ->
          let module' = withCategory Module (S.Module id rest)
          in withCategory Program (S.Indexed (comments <> [module']))
        _ -> withRanges range Error children (S.Error children)
    _ -> withRanges range Error children (S.Error children)
  (Other "import_declaration", _) -> toImports children
  (Function, _) -> withDefaultInfo $ case children of
    [id, params, block] -> S.Function id (toList $ unwrap params) (toList $ unwrap block)
    rest -> S.Error rest
  (For, [body]) | Other "block" <- Info.category (extract body) -> withDefaultInfo $ S.For [] (toList (unwrap body))
  (For, [forClause, body]) | Other "for_clause" <- Info.category (extract forClause) -> withDefaultInfo $ S.For (toList (unwrap forClause)) (toList (unwrap body))
  (For, [rangeClause, body]) | Other "range_clause" <- Info.category (extract rangeClause) -> withDefaultInfo $ S.For (toList (unwrap rangeClause)) (toList (unwrap body))
  (TypeDecl, _) -> toTypeDecl children
  (StructTy, _) -> toStructTy children
  (FieldDecl, _) -> toFieldDecl children
  (Switch, _) ->
    case Prologue.break isCaseClause children of
      (clauses, cases) -> withDefaultInfo $ case clauses of
        [id] -> S.Switch (Just id) cases -- type_switch_statement
        [] -> S.Switch Nothing (toCase <$> cases)
        _ -> S.Switch (Just (withCategory ExpressionStatements (S.Indexed clauses))) (toCase <$> cases)
      where
        isCaseClause = (== Case) . Info.category . extract
        toCase clause = case toList (unwrap clause) of
          clause' : rest -> case toList (unwrap clause') of
            [clause''] -> withCategory Case $ S.Case clause'' rest
            [] -> withCategory DefaultCase $ S.DefaultCase rest
            rest -> withCategory Error $ S.Error rest
          [] -> withCategory Error $ S.Error [clause]
  (ParameterDecl, _) -> withDefaultInfo $ case children of
    [param, ty] -> S.ParameterDecl (Just ty) param
    [param] -> S.ParameterDecl Nothing param
    _ -> S.Error children
  (Assignment, _) -> toVarAssignment children
  (Select, _) -> withDefaultInfo $ S.Select (toCommunicationCase =<< children)
    where toCommunicationCase = toList . unwrap
  (Go, _) -> withDefaultInfo $ toExpression S.Go children
  (Defer, _) -> withDefaultInfo $ toExpression S.Defer children
  (SubscriptAccess, _) -> withDefaultInfo $ toSubscriptAccess children
  (IndexExpression, _) -> withDefaultInfo $ toSubscriptAccess children
  (Slice, _) -> sliceToSubscriptAccess children
  (Other "composite_literal", _) -> toLiteral children
  (TypeAssertion, _) -> withDefaultInfo $ case children of
    [a, b] -> S.TypeAssertion a b
    rest -> S.Error rest
  (TypeConversion, _) -> withDefaultInfo $ case children of
    [a, b] -> S.TypeConversion a b
    rest -> S.Error rest
  -- TODO: Handle multiple var specs
  (Other "var_declaration", _) -> toVarDecls children
  (VarAssignment, _) -> toVarAssignment children
  (VarDecl, _) -> toVarAssignment children
  (If, _) -> toIfStatement children
  (FunctionCall, _) -> withDefaultInfo $ case children of
    [id] -> S.FunctionCall id []
    id : rest -> S.FunctionCall id rest
    rest -> S.Error rest
  (Other "const_declaration", _) -> toConsts children
  (AnonymousFunction, _) -> withDefaultInfo $ case children of
    [params, _, body] -> case toList (unwrap params) of
      [params'] -> S.AnonymousFunction (toList $ unwrap params') (toList $ unwrap body)
      rest -> S.Error rest
    rest -> S.Error rest
  (PointerTy, _) -> withDefaultInfo $ case children of
    [ty] -> S.Ty ty
    rest -> S.Error rest
  (ChannelTy, _) -> withDefaultInfo $ case children of
    [ty] -> S.Ty ty
    rest -> S.Error rest
  (Send, _) -> withDefaultInfo $ case children of
    [channel, expr] -> S.Send channel expr
    rest -> S.Error rest
  (Operator, _) -> withDefaultInfo $ S.Operator children
  (FunctionTy, _) ->
    let params = withRanges range Params children $ S.Indexed children
    in withDefaultInfo $ S.Ty params
  (IncrementStatement, _) ->
    withDefaultInfo $ S.Leaf $ toText source
  (DecrementStatement, _) ->
    withDefaultInfo $ S.Leaf $ toText source
  (QualifiedIdentifier, _) ->
    withDefaultInfo $ S.Leaf $ toText source
  (Break, _) -> toBreak children
  (Continue, _) -> toContinue children
  (Pair, _) -> toPair children
  (Method, _) -> toMethod children
  _ -> withDefaultInfo $ case children of
    [] -> S.Leaf $ toText source
    _ -> S.Indexed children
  where
    toMethod = \case
      [params, name, fun] -> withDefaultInfo (S.Method name Nothing (toList $ unwrap params) (toList $ unwrap fun))
      [params, name, outParams, fun] ->
        let params' = toList (unwrap params)
            outParams' = toList (unwrap outParams)
            allParams = params' <> outParams'
        in withDefaultInfo (S.Method name Nothing allParams (toList $ unwrap fun))
      [params, name, outParams, ty, fun] ->
        let params' = toList (unwrap params)
            outParams' = toList (unwrap outParams)
            allParams = params' <> outParams'
        in withDefaultInfo (S.Method name (Just ty) allParams (toList $ unwrap fun))
      rest -> withCategory Error (S.Error rest)
    toPair = \case
      [key, value] -> withDefaultInfo (S.Pair key value)
      rest -> withCategory Error (S.Error rest)
    toBreak = \case
      [label] -> withDefaultInfo (S.Break (Just label))
      [] -> withDefaultInfo (S.Break Nothing)
      rest -> withCategory Error (S.Error rest)
    toContinue = \case
      [label] -> withDefaultInfo (S.Continue (Just label))
      [] -> withDefaultInfo (S.Continue Nothing)
      rest -> withCategory Error (S.Error rest)

    toStructTy children =
      withDefaultInfo (S.Ty (withRanges range FieldDeclarations children (S.Indexed children)))

    toLiteral = \case
      children@[ty, _] -> case Info.category (extract ty) of
        ArrayTy -> toImplicitArray children
        DictionaryTy -> toMap children
        SliceTy -> sliceToSubscriptAccess children
        _ -> toStruct children
      rest -> withRanges range Error rest $ S.Error rest
    toImplicitArray = \case
      [ty, values] -> withCategory ArrayLiteral (S.Array (Just ty) (toList $ unwrap values))
      rest -> withRanges range Error rest $ S.Error rest
    toMap = \case
      [ty, values] -> withCategory DictionaryLiteral (S.Object (Just ty) (toList $ unwrap values))
      rest -> withRanges range Error rest $ S.Error rest
    toStruct = \case
      [] -> withCategory Struct (S.Struct Nothing [])
      [ty] -> withCategory Struct (S.Struct (Just ty) [])
      [ty, values] -> withCategory Struct (S.Struct (Just ty) (toList $ unwrap values))
      rest -> withRanges range Error rest $ S.Error rest
    toFieldDecl = \case
      [idList, ty] ->
        case Info.category (extract ty) of
          StringLiteral -> withCategory FieldDecl (S.FieldDecl (toIdent (toList (unwrap idList))) Nothing (Just ty))
          _ -> withCategory FieldDecl (S.FieldDecl (toIdent (toList (unwrap idList))) (Just ty) Nothing)
      [idList] ->
        withCategory FieldDecl (S.FieldDecl (toIdent (toList (unwrap idList))) Nothing Nothing)
      [idList, ty, tag] ->
        withCategory FieldDecl (S.FieldDecl (toIdent (toList (unwrap idList))) (Just ty) (Just tag))
      rest -> withRanges range Error rest (S.Error rest)

      where
        toIdent = \case
          [ident] -> ident
          rest -> withRanges range Error rest (S.Error rest)


    toExpression f = \case
      [expr] -> f expr
      rest -> S.Error rest
    toSubscriptAccess = \case
      [a, b] -> S.SubscriptAccess a b
      rest -> S.Error rest
    sliceToSubscriptAccess = \case
      a : rest ->
        let sliceElement = withRanges range Element rest $ S.Fixed rest
        in withCategory Slice (S.SubscriptAccess a sliceElement)
      rest -> withRanges range Error rest $ S.Error rest

    toIfStatement children = case Prologue.break ((Other "block" ==) . Info.category . extract) children of
      (clauses, blocks) ->
        let clauses' = withRanges range ExpressionStatements clauses (S.Indexed clauses)
            blocks' = foldMap (toList . unwrap) blocks
        in withDefaultInfo (S.If clauses' blocks')

    toTypeDecl = \case
      [identifier, ty] -> withDefaultInfo $ S.TypeDecl identifier ty
      rest -> withRanges range Error rest $ S.Error rest

    toImports imports =
      withDefaultInfo $ S.Indexed (imports >>= toImport)
      where
        toImport i = case toList (unwrap i) of
          [importName] -> [ withCategory Import (S.Import importName []) ]
          rest@(_:_) -> [ withRanges range Error rest (S.Error rest)]
          [] -> []

    toVarDecls children = withDefaultInfo (S.Indexed children)

    toConsts constSpecs = withDefaultInfo (S.Indexed constSpecs)

    toVarAssignment = \case
        [idList, ty] | Info.category (extract ty) == Identifier ->
          let ids = toList (unwrap idList)
              idList' = (\id -> withRanges range VarDecl [id] (S.VarDecl id (Just ty))) <$> ids
          in withRanges range ExpressionStatements idList' (S.Indexed idList')
        [idList, expressionList] | Info.category (extract expressionList) == Other "expression_list" ->
          let assignments' = zipWith (\id expr ->
                withCategory VarAssignment $ S.VarAssignment id expr)
                (toList $ unwrap idList) (toList $ unwrap expressionList)
          in withRanges range ExpressionStatements assignments' (S.Indexed assignments')
        [idList, _, expressionList] ->
          let assignments' = zipWith (\id expr ->
                withCategory VarAssignment $ S.VarAssignment id expr) (toList $ unwrap idList) (toList $ unwrap expressionList)
          in withRanges range ExpressionStatements assignments' (S.Indexed assignments')
        [idList] -> withDefaultInfo (S.Indexed [idList])
        rest -> withRanges range Error rest (S.Error rest)

    withRanges originalRange category' terms syntax =
      let ranges' = getField . extract <$> terms
          sourceSpans' = getField . extract <$> terms
      in
      cofree ((unionRangesFrom originalRange ranges' :. category' :. unionSourceSpansFrom sourceSpan sourceSpans' :. Nil) :< syntax)

    withCategory category syntax =
      cofree ((range :. category :. sourceSpan :. Nil) :< syntax)

    withDefaultInfo = withCategory category

categoryForGoName :: Text -> Category
categoryForGoName = \case
  "identifier" -> Identifier
  "int_literal" -> NumberLiteral
  "float_literal" -> FloatLiteral
  "comment" -> Comment
  "return_statement" -> Return
  "interpreted_string_literal" -> StringLiteral
  "raw_string_literal" -> StringLiteral
  "binary_expression" -> RelationalOperator
  "function_declaration" -> Function
  "func_literal" -> AnonymousFunction
  "call_expression" -> FunctionCall
  "selector_expression" -> SubscriptAccess
  "index_expression" -> IndexExpression
  "slice_expression" -> Slice
  "parameters" -> Args
  "short_var_declaration" -> VarDecl
  "var_spec" -> VarAssignment
  "const_spec" -> VarAssignment
  "assignment_statement" -> Assignment
  "source_file" -> Module
  "if_statement" -> If
  "for_statement" -> For
  "expression_switch_statement" -> Switch
  "type_switch_statement" -> Switch
  "expression_case_clause" -> Case
  "type_case_clause" -> Case
  "select_statement" -> Select
  "communication_case" -> Case
  "defer_statement" -> Defer
  "go_statement" -> Go
  "type_assertion_expression" -> TypeAssertion
  "type_conversion_expression" -> TypeConversion
  "keyed_element" -> Pair
  "struct_type" -> StructTy
  "map_type" -> DictionaryTy
  "array_type" -> ArrayTy
  "implicit_length_array_type" -> ArrayTy
  "parameter_declaration" -> ParameterDecl
  "expression_case" -> Case
  "type_spec" -> TypeDecl
  "field_declaration" -> FieldDecl
  "pointer_type" -> PointerTy
  "slice_type" -> SliceTy
  "element" -> Element
  "literal_value" -> Literal
  "channel_type" -> ChannelTy
  "send_statement" -> Send
  "unary_expression" -> Operator
  "function_type" -> FunctionTy
  "inc_statement" -> IncrementStatement
  "dec_statement" -> DecrementStatement
  "qualified_identifier" -> QualifiedIdentifier
  "break_statement" -> Break
  "continue_statement" -> Continue
  "rune_literal" -> RuneLiteral
  "method_declaration" -> Method
  s -> Other (toS s)
