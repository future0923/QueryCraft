import keyword_rules from "./grammar/keywords.js";
import type_rules from "./grammar/types.js";
import column_list_rules from "./grammar/column-lists.js";
import expression_rules from "./grammar/expressions.js";
import transaction_rules from "./grammar/transactions.js";
import statement_rules from "./grammar/statements/index.js";

export default grammar({
  name: 'sql',

  extras: $ => [
    /\s\n/,
    /\s/,
    $.comment,
    $.optimizer_hint,
    $.executable_comment,
  ],


  externals: $ => [
    $._dollar_quoted_string_start_tag,
    $._dollar_quoted_string_end_tag,
    $._dollar_quoted_string,
  ],

  conflicts: $ => [
    [$.object_reference, $._qualified_field],
    [$.field, $._qualified_field],
    [$._column, $._qualified_field],
    [$.object_reference],
    [$.between_expression, $.binary_expression],
    [$.time],
    [$.timestamp],
  ],

  precedences: $ => [
    [
      'binary_is',
      'unary_not',
      'binary_exp',
      'binary_times',
      'binary_plus',
      'unary_other',
      'binary_other',
      'binary_in',
      'binary_compare',
      'binary_relation',
      'pattern_matching',
      'between',
      'clause_connective',
      'clause_disjunctive',
    ],
  ],

  word: $ => $._identifier,

  rules: {
    program: $ => seq(
      // any number of transactions, statements, or blocks with a terminating ;
      // delimiter directives are represented so QueryCraft can reject routine
      // scripts without maintaining a second statement scanner.
      repeat(choice(
        seq(
          choice(
            $.transaction,
            $.statement,
            $.block,
          ),
          ';',
        ),
        $.delimiter_directive,
      )),
      // optionally, a single statement without a terminating ;
      optional(
        $.statement,
      ),
    ),

    delimiter_directive: $ => seq(
      $.keyword_delimiter,
      optional($.delimiter_value),
    ),
    delimiter_value: _ => token(/[^\s]+/),

    // MySQL only recognizes -- as a comment introducer when the next
    // character is whitespace or a control character.
    comment: _ => token(prec(1, choice(
      /--[\x00-\x09\x0B-\x20][^\r\n]*/,
      /--\n/,
      /#[^\r\n]*/,
      /\/\*[^*]*\*+(?:[^/*][^*]*\*+)*\//,
    ))),
    optimizer_hint: _ => token(prec(
      2,
      /\/\*\+[^*]*\*+(?:[^/*][^*]*\*+)*\//,
    )),
    executable_comment: _ => token(prec(
      2,
      /\/\*![^*]*\*+(?:[^/*][^*]*\*+)*\//,
    )),

    ...keyword_rules,
    ...type_rules,
    ...column_list_rules,
    ...expression_rules,
    ...transaction_rules,
    ...statement_rules,

  }

});
