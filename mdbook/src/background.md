# Background and Sources

Mica is a relation-based, persistent, deductive programming system with both object and relational
aspects. This chapter explains the idea it is built around, where that idea comes from, and which
earlier systems it learns from. The argument is developed at length in Ryan Daum's outline
[*A Relational Theory of Objecthood and Identity*](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2),
which the Mica specifications also take as their introduction.

## Objects Without Boxes

Object-oriented systems usually start from identity: first there is an object, then its fields,
methods, and messages. Services, components, and actors often repeat the same move at a larger
scale, binding identity, private state, and owned behaviour behind a boundary. Mica starts from the
other end. Knowledge is a set of propositions, stored as facts in named relations, and the things
those facts mention are referred to by durable reference values.

Such a value, written `#alice`, is a **handle**. A handle lets facts, transactions, rules,
permissions, and histories coordinate reference. It does not decide what the thing is, which
attributes belong to it, which behaviour it owns, or which taxonomy gives it meaning. Those are facts
and rules like any others, open to query, revision, and authority. The
[Values](./language/values.md#identities-and-delegated-values) chapter calls handles identity
values; the two names mean the same thing.

Four notions stay separate:

1. **Handle equality**: two mentions use the same reference value (`#lamp == #lamp`).
2. **Equivalence**: a relation, often contextual and authority-bound, such as `SameAs(a, b)`.
3. **Objecthood**: an object is a view computed over the facts around a handle, not a container.
4. **Identity**: a defended claim of sameness or continuity, supported by relations and history.

```mica,eval
make_identity(:morning_star)
make_identity(:evening_star)
make_relation(:SameAs, 2)
assert SameAs(#morning_star, #evening_star)
require #morning_star != #evening_star        // two handles
require SameAs(#morning_star, #evening_star)  // one claim about what they name
```

Asserting `SameAs` does not merge the two handles. It records a claim that queries, rules, and
authority can use, dispute, or retract.

## Lineage

Mica grows out of lessons from [mooR](https://github.com/timbran-project/moor), a modern rewrite of
LambdaMOO. From that line it inherits image-based authoring, multiuser worlds, long-lived shared
state, and extension while the world runs. The earlier, unfinished Mica of 2001–2004 belonged to the
same family as MOO and ColdMUD.

It also draws on:

- **Codd's relational model** for starting from propositions and composing queries over them, and
  on his RM/T work for system-assigned surrogates that identify without describing, which is what a
  handle is.
- **Smalltalk** for the live image as the source of truth, with code filed into and out of it.
- **Self** for prototype delegation in place of class inheritance; Mica states delegation as the
  `Delegates` relation.
- **Multimethods and predicate dispatch** for choosing behaviour by the roles of all arguments
  rather than by one receiver.
- **Datalog** for derived relations and rules, including recursion.
- **Tuple spaces** for shared facts that independent tasks read, write, and react to.
- **"Out of the Tar Pit"** for keeping essential state apart from derived data and control.

## Sources

- E. F. Codd, "A Relational Model of Data for Large Shared Data Banks," *Communications of the ACM*
  13(6), 1970.
- E. F. Codd, "Extending the Database Relational Model to Capture More Meaning," *ACM Transactions
  on Database Systems* 4(4), 1979.
- C. J. Date, *SQL and Relational Theory: How to Write Accurate SQL Code*, O'Reilly, 2009.
- C. J. Date and H. Darwen, *Databases, Types, and the Relational Model: The Third Manifesto*, 3rd
  ed., Addison-Wesley, 2006.
- H. G. Baker, "Equal Rights for Functional Objects or, The More Things Change, The More They Are the
  Same," 1993.
- B. Moseley and P. Marks, "Out of the Tar Pit," 2006.
- F. P. Brooks, "No Silver Bullet," *IEEE Computer* 20(4), 1987.
- A. Kay, "Clarification of 'object-oriented'," email to Stefan Ram, 2003.
- A. Goldberg and D. Robson, *Smalltalk-80: The Language and its Implementation*, Addison-Wesley,
  1983.
- D. Ungar and R. B. Smith, "Self: The Power of Simplicity," OOPSLA 1987.
- R. B. Smith and D. Ungar, "A Simple and Unifying Approach to Subjective Objects," *Theory and
  Practice of Object Systems* 2(3), 1996.
- C. Chambers, "Object-Oriented Multi-Methods in Cecil," ECOOP 1992.
- M. Ernst, C. Kaplan, and C. Chambers, "Predicate Dispatching: A Unified Theory of Dispatch,"
  ECOOP 1998.
- D. Gelernter, "Generative Communication in Linda," *ACM Transactions on Programming Languages and
  Systems* 7(1), 1985.
- S. Ceri, G. Gottlob, and L. Tanca, "What You Always Wanted to Know About Datalog (And Never Dared
  to Ask)," *IEEE Transactions on Knowledge and Data Engineering* 1(1), 1989.
- W. Chen and D. S. Warren, "Tabled Evaluation with Delaying for General Logic Programs," *Journal of
  the ACM* 43(1), 1996.
- M. Aref et al., "Rel: A Programming Language for Relational Data," arXiv:2504.10323, 2025.
- W3C, *RDF 1.1 Concepts and Abstract Syntax*, 2014; *OWL 2 Web Ontology Language Primer*, 2012.
- P. Curtis, *LambdaMOO Programmer's Manual*; R. Daum, [mooR](https://github.com/timbran-project/moor).
