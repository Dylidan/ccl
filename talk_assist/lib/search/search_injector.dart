import 'package:flutter/foundation.dart';

import 'serper_search_service.dart';
import 'search_config.dart';

/// Decides whether a user message needs a web search,
/// if so fetches result and formats them into a context block
/// that gets prepended to the user's message before the LLM sees it.
class SearchInjector {
  SearchInjector({
    SerperSearchService? searchService,
  }) : _searchService = searchService ?? SerperSearchService();

  final SerperSearchService _searchService;

  /// Returns the user input, potentially with search results prepended.
  /// if no keywords match or the search fails, returns the original
  /// [userInput] unchanged so the LLM call always proceeds normally.
  Future<String> injectIfNeeded(String userInput) async {
    final normalized = userInput.trim();
    if (normalized.isEmpty) {
      return normalized;
    }

    if (!_shouldSearch(normalized)) {
      return normalized;
    }

    if (kDebugMode) {
      debugPrint('SearchInjector: trigger detected, searching for "$normalized"');
    }

    try {
      final results = await _searchService.search(normalized);

      if (results.isEmpty) {
        if (kDebugMode) {
          debugPrint('SearchInjector: no results, skipping injection');
        }
        return normalized;
      }

      final injected = _buildInjectedPrompt(
        userInput: normalized,
        results: results,
      );

      if (kDebugMode) {
        debugPrint(
          'SearchInjector: injected ${results.length} results '
              '(promptChars=${injected.length})',
        );
      }

      return injected;
    } catch (e) {
      /// Search failing should never block the LLM call
      if (kDebugMode) {
        debugPrint('SearchInjector: search failed, proceeding without results: $e');
      }
      return normalized;
    }
  }

  /// Returns true if the message contains any trigger keyword.
  bool _shouldSearch(String input) {
    final lower = input.toLowerCase();
    for (final keyword in SearchConfig.triggerKeywords) {
      if (lower.contains(keyword)) {
        if (kDebugMode) {
          debugPrint('SearchInjector: matched keyword "$keyword"');
        }
        return true;
      }
    }
    return false;
  }

  /// Formats search results into a context block prepended to the user input.
  String _buildInjectedPrompt({
    required String userInput,
    required List<SerperSearchResult> results,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('[Web search results for "$userInput"]');

    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      buffer.writeln('${i + 1}. ${result.title}');
      if (result.snippet.isNotEmpty) {
        buffer.writeln('   ${result.snippet}');
      }
      buffer.writeln('   ${result.url}');
    }
    /// Helps the model understand which part is context and
    /// which part is the actual question
    buffer.writeln('---');
    buffer.writeln('User asked: $userInput');

    return buffer.toString();
  }
}