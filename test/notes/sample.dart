/// Shared sample document for notes tests.
const sampleNotes = r'''
# Compactness in Metric Spaces

## 1. Definitions

**Definition 1.1.** A metric space $(X,d)$ is *compact* if every open cover $\{U_\alpha\}_{\alpha\in A}$ of $X$ admits a finite subcover.

$$
\begin{aligned}
\|f\|_{L^p} &= \left(\int_X |f|^p \, d\mu\right)^{1/p} \\
&\le \mu(X)^{\frac1p-\frac1q}\,\|f\|_{L^q}
\end{aligned}
$$

**Theorem 1.2 (Heine–Borel).** A subset $K\subseteq\mathbb{R}^n$ is compact iff it is closed and bounded.

*Proof.* Suppose $K$ is closed and bounded... $\blacksquare$

- Item with $\varepsilon>0$ and `code $x$`
1. Numbered $\sum_{n=1}^\infty \frac{1}{n^2}=\frac{\pi^2}{6}$
''';

/// Adds an over-wide display equation, an invalid formula, a table, quote, code.
const sampleNotesHard = '$sampleNotes\n'
    r'''
$$
a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13} + a_{14} + a_{15} + a_{16} + a_{17} + a_{18} + a_{19} + a_{20} = \sum_{k=1}^{20} a_k
$$

An invalid inline formula $\frac{1}{$ and display:

$$
\notacommand{x} \begin{foo}
$$

> Quoted remark with $x^2$.

| a | b |
|---|---|
| $x$ | 2 |

```
code $not math$
```

---

Price is \$5 and \$6.
''';
