import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'search_config.dart';

/// A single search result returned by Serper.
class SerperSearchResult {
  const SerperSearchResult({
    required this.title,
    required this.snippet,
    required this.url,
  });

  final String title;
  final String snippet;
  final String url;
}

/// Calls the Serper (Google Search) API and returns a list of results.
/// Throws [SearchUnavailableException] on network errors, bad status codes,
/// missing API key, or empty responses.
class SerperSearchService {
  SerperSearchService({
    String? apiKey,
    http.Client? httpClient,
  })  : _apiKey = apiKey ?? dotenv.env['SERPER_KEY'] ?? '',
        _client = httpClient ?? http.Client();

  final String _apiKey;
  final http.Client _client;

  static const Duration _requestTimeout = Duration(seconds: 10);

  /// Fetches up to [SearchConfig.maxResults] results for [query].
  Future<List<SerperSearchResult>> search(String query) async {
    if (_apiKey.isEmpty) {
      throw const SearchUnavailableException(
        'Serper API key not set. Add SERPER_KEY to your .env file.',
      );
    }

    http.Response response;
    try {
      response = await _client.post(
        Uri.parse(SearchConfig.endpoint),
        headers: {
          'X-API-KEY': _apiKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'q': query,
          'num': SearchConfig.maxResults,
        }),
      ).timeout(_requestTimeout);
    } catch (e) {
      throw SearchUnavailableException('Serper request failed: $e');
    }

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint(
          'Serper error ${response.statusCode}: ${response.body}',
        );
      }
      throw SearchUnavailableException(
        'Serper returned HTTP ${response.statusCode}.',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final organic = data['organic'] as List<dynamic>?;

    if (organic == null || organic.isEmpty) {
      if (kDebugMode) {
        debugPrint('Serper returned no results for: "$query"');
      }
      return [];
    }

    final results = <SerperSearchResult>[];
    for (final item in organic) {
      if (item is! Map<String, dynamic>) continue;

      final title = item['title']?.toString().trim() ?? '';
      final url = item['link']?.toString().trim() ?? '';
      var snippet = item['snippet']?.toString().trim() ?? '';

      /// Truncate long snippets to keep token usage predictable
      if (snippet.length > SearchConfig.maxSnippetLength) {
        snippet = '${snippet.substring(0, SearchConfig.maxSnippetLength)}...';
      }

      if (title.isEmpty && snippet.isEmpty) continue;

      results.add(SerperSearchResult(
        title: title,
        snippet: snippet,
        url: url,
      ));
    }

    if (kDebugMode) {
      debugPrint(
        'Serper returned ${results.length} results for: "$query"',
      );
    }

    return results;
  }
}

/// Exception thrown when the search cannot be completed.
class SearchUnavailableException implements Exception {
  const SearchUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'SearchUnavailableException: $message';
}