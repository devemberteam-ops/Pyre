import 'package:http/http.dart' as http;

/// Native: the default `http.Client` (IOClient) already streams response bodies
/// incrementally, so SSE token streaming works as-is. Plain passthrough.
http.Client makeStreamingClient() => http.Client();
