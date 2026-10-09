const Token = @import("Token.zig");
const Span = Token.Span;

pub const Chunk = struct {
    span: Span,
    block: Block,
};

pub const Block = struct {
    span: Span,
    statements: []Statement,
    ret_statement: ?RetStatement,
};

pub const Statement = union(enum) {
    empty: *EmptyStatement,

    assignment: *AssignmentStatement,
    function_call: *FunctionCall,

    label: *Label,
    @"break": *BreakStatement,
    goto: *GotoStatement,

    do: *DoStatement,
    @"while": *WhileStatement,
    repeat: *RepeatStatement,
    @"if": *IfStatement,

    numeric_for: *ForStatement,
    generic_for: *ForInStatement,

    function_definition: *FunctionDefinition,
    local_function_definition: *LocalFunctionDefinition,
    local_declaration: *LocalDeclaration,
};

pub const EmptyStatement = struct {
    span: Span,
};

pub const AssignmentStatement = struct {
    span: Span,
    variables: []Variable,
    equals_span: Span,
    expressions: []Expression,
};

pub const RetStatement = struct {
    span: Span,
    return_span: Span,
    expressions: []Expression,
    semicolon_span: ?Span,
};

pub const Label = struct {
    span: Span,
    open_span: Span,
    name: Identifier,
    close_span: Span,
};

pub const BreakStatement = struct {
    span: Span,
    break_span: Span,
};

pub const GotoStatement = struct {
    span: Span,
    goto_span: Span,
    name: Identifier,
};

pub const DoStatement = struct {
    span: Span,
    do_span: Span,
    block: Block,
    end_span: Span,
};

pub const WhileStatement = struct {
    span: Span,
    while_span: Span,
    condition: Expression,
    do_span: Span,
    block: Block,
    end_span: Span,
};

pub const RepeatStatement = struct {
    span: Span,
    repeat_span: Span,
    block: Block,
    until_span: Span,
    condition: Expression,
};

pub const IfStatement = struct {
    span: Span,
    if_span: Span,
    condition: Expression,
    then_span: Span,
    block: Block,
    elseif_clauses: []ElseIfClause,
    else_clause: ?ElseClause,
    end_span: Span,
};

pub const ElseIfClause = struct {
    span: Span,
    elseif_span: Span,
    condition: Expression,
    then_span: Span,
    block: Block,
};

pub const ElseClause = struct {
    span: Span,
    else_span: Span,
    block: Block,
};

pub const ForStatement = struct {
    span: Span,
    for_span: Span,
    name: Identifier,
    equals_span: Span,
    initial: Expression,
    first_comma_span: Span,
    limit: Expression,
    second_comma_span: ?Span,
    step: ?Expression,
    do_span: Span,
    block: Block,
    end_span: Span,
};

pub const ForInStatement = struct {
    span: Span,
    for_span: Span,
    names: []Identifier,
    in_span: Span,
    expressions: []Expression,
    do_span: Span,
    block: Block,
    end_span: Span,
};

pub const FunctionDefinition = struct {
    span: Span,
    function_span: Span,
    name: FunctionName,
    body: FunctionBody,
};

pub const LocalFunctionDefinition = struct {
    span: Span,
    local_span: Span,
    function_span: Span,
    name: Identifier,
    body: FunctionBody,
};

pub const LocalDeclaration = struct {
    span: Span,
    local_span: Span,
    names: []LocalName,
    equals_span: ?Span,
    expressions: []Expression,
};

pub const LocalName = struct {
    span: Span,
    name: Identifier,
    attribute: ?Attribute,
};

pub const Attribute = struct {
    span: Span,
    open_span: Span,
    name: Identifier,
    close_span: Span,
};

pub const FunctionName = struct {
    span: Span,
    first: Identifier,
    fields: []Identifier,
    colon_span: ?Span,
    method: ?Identifier,
};

pub const FunctionBody = struct {
    span: Span,
    open_paren_span: Span,
    parameters: []Parameter,
    vararg: ?VarargParameter,
    close_paren_span: Span,
    block: Block,
    end_span: Span,
};

pub const Parameter = struct {
    span: Span,
    name: Identifier,
};

pub const VarargParameter = struct {
    span: Span,
    dots_span: Span,
};

pub const Variable = union(enum) {
    name: Identifier,
    index: IndexExpression,
    field: FieldExpression,
};

pub const FunctionCall = struct {
    span: Span,
    expression: Expression,
    // set for `object:name(...)`, which passes the object as the first
    // argument, unlike `object.name(...)`
    colon_span: ?Span,
    method: ?Identifier,
    arguments: Arguments,
};

pub const Arguments = union(enum) {
    parenthesized: ParenthesizedArguments,
    table: TableConstructor,
    string: StringLiteral,
};

pub const ParenthesizedArguments = struct {
    span: Span,
    open_paren_span: Span,
    expressions: []Expression,
    close_paren_span: Span,
};

pub const IndexExpression = struct {
    span: Span,
    object: Expression,
    open_bracket_span: Span,
    index: Expression,
    close_bracket_span: Span,
};

pub const FieldExpression = struct {
    span: Span,
    object: Expression,
    dot_span: Span,
    name: Identifier,
};

pub const Expression = union(enum) {
    nil: *NilExpression,
    boolean: *BooleanExpression,
    number: *NumberExpression,
    string: *StringLiteral,
    vararg: *VarargExpression,

    variable: *Variable,

    unary: *UnaryExpression,
    binary: *BinaryExpression,

    function: *FunctionExpression,
    table: *TableConstructor,

    parenthesized: *ParenthesizedExpression,

    function_call: *FunctionCall,
};

pub const NilExpression = struct {
    span: Span,
};

pub const BooleanExpression = struct {
    span: Span,
    value: bool,
};

pub const NumberExpression = struct {
    span: Span,
    value: f64,
};

pub const StringLiteral = struct {
    span: Span,
    // the source between the delimiters, escapes as written
    raw: []const u8,
    // the decoded bytes, escapes resolved
    value: []const u8,
};

pub const VarargExpression = struct {
    span: Span,
    dots_span: Span,
};

pub const UnaryExpression = struct {
    span: Span,
    operator: UnaryOperator,
    operator_span: Span,
    expression: Expression,
};

pub const BinaryExpression = struct {
    span: Span,
    left: Expression,
    operator: BinaryOperator,
    operator_span: Span,
    right: Expression,
};

pub const UnaryOperator = enum {
    negation, // -
    not,
    length, // #
    bitwise_not, // ~
};

pub const BinaryOperator = enum {
    add, // +
    subtract, // -
    multiply, // *
    divide, // /
    floor_divide, // //
    modulo, // %
    power, // ^
    bitwise_and, // &
    bitwise_or, // |
    bitwise_xor, // ~
    shift_left, // <<
    shift_right, // >>
    concat, // ..
    less_than, // <
    less_equal, // <=
    greater_than, // >
    greater_equal, // >=
    equal, // ==
    not_equal, // ~=
    @"and",
    @"or",
};

pub const FunctionExpression = struct {
    span: Span,
    function_span: Span,
    body: FunctionBody,
};

pub const ParenthesizedExpression = struct {
    span: Span,
    open_paren_span: Span,
    expression: Expression,
    close_paren_span: Span,
};

pub const TableConstructor = struct {
    span: Span,
    open_brace_span: Span,
    fields: []TableField,
    close_brace_span: Span,
};

pub const TableField = union(enum) {
    indexed: IndexedField,
    named: NamedField,
    expression: ExpressionField,
};

pub const IndexedField = struct {
    span: Span,
    open_bracket_span: Span,
    key: Expression,
    close_bracket_span: Span,
    equals_span: Span,
    value: Expression,
};

pub const NamedField = struct {
    span: Span,
    name: Identifier,
    equals_span: Span,
    value: Expression,
};

pub const ExpressionField = struct {
    span: Span,
    expression: Expression,
};

pub const Identifier = struct {
    span: Span,
    name: []const u8,
};
