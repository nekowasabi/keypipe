using Keypipe.Core;

namespace Keypipe.Core.Tests;

public sealed class FactsTests
{
    // V13: glob matching follows fnmatch(3) (Swift Term.matches), not regex.
    // In a bracket class, "!" negates: only the listed characters are
    // excluded, and the "!" itself is an ordinary matchable character.
    [Fact]
    public void GlobNegatedClassExcludesItsMembers()
    {
        Assert.False(Term.GlobMatch("[!a]", "a"));
        Assert.True(Term.GlobMatch("[!a]", "b"));
        Assert.True(Term.GlobMatch("[!a]", "!"));
    }

    // V13: "^" has no special meaning in a fnmatch class: it is a literal
    // member, and non-members do not match.
    [Fact]
    public void GlobCaretInClassIsLiteral()
    {
        Assert.True(Term.GlobMatch("[^a]", "^"));
        Assert.True(Term.GlobMatch("[^a]", "a"));
        Assert.False(Term.GlobMatch("[^a]", "b"));
    }

    // V13: a backslash escapes the next character, inside and outside a
    // class, so "\*" is a literal star and "a\b" matches "ab".
    [Fact]
    public void GlobBackslashEscapesTheNextCharacter()
    {
        Assert.True(Term.GlobMatch("\\*", "*"));
        Assert.False(Term.GlobMatch("\\*", "x"));
        Assert.True(Term.GlobMatch("a\\b", "ab"));
        Assert.False(Term.GlobMatch("a\\b", "a\\b"));
    }

    // V13: an invalid range such as [z-a] never matches and never throws
    // (fnmatch reports no match); evaluation must not crash the fire path.
    [Fact]
    public void GlobInvalidRangeNeverMatchesAndNeverThrows()
    {
        Assert.False(Term.GlobMatch("[z-a]", "m"));
        Assert.False(Term.GlobMatch("[z-a]", "z"));
    }

    // V13: the ordinary patterns configs actually use keep matching.
    [Fact]
    public void GlobOrdinaryPatternsStillMatch()
    {
        Assert.True(Term.GlobMatch("*github.com*", "https://github.com/"));
        Assert.True(Term.GlobMatch("com.apple.*", "com.apple.TextEdit"));
        Assert.True(Term.GlobMatch("[a-c]x", "bx"));
        Assert.False(Term.GlobMatch("[a-c]x", "dx"));
        Assert.True(Term.GlobMatch("a?c", "abc"));
        Assert.False(Term.GlobMatch("a?c", "ac"));
    }
}
