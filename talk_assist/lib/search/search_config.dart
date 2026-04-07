///configuration for internet search capabilities
class SearchConfig {
  const SearchConfig._();

  /// Serper search API endpoint
  static const String endpoint =
      'https://google.serper.dev/search';

  /// Maximum number of results to fetch and inject into the prompt
  static const int maxResults = 3;

  /// Maximum character length for each result snippet
  /// keeps token usage predictable (limited options for free online search
  /// capabilities, serper allows for 2,500 queries a month)
  static const int maxSnippetLength = 200;

  /// Keywords that trigger a web search
  static const List<String> triggerKeywords = [
    // Time-sensitive
    'today',
    'tonight',
    'yesterday',
    'this week',
    'this month',
    'right now',
    'currently',
    'latest',
    'recent',
    'news',
    'weather',
    'forecast',
    'score',
    'standings',
    // Factual lookup
    'who is',
    'what is',
    'where is',
    'when did',
    'how much',
    'how many',
    'price of',
    'cost of',
    'population of',
    'capital of',
  ];
}