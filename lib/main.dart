library sci_tally_tool;

import "dart:async";
import "dart:io" show Platform;
import "dart:convert" show UTF8, BASE64, Encoding, JSON;
import "package:logging/logging.dart";
import "package:intl/intl.dart" show DateFormat;
import 'package:http/http.dart' as http;

final Logger log = new Logger("main");

String envVarRequired(String key) {
  if (Platform.environment.containsKey(key)) {
    return Platform.environment[key];
  }

  throw "Environment variable \"${key}\" was empty.";
}

String envVarDefault(String key, String defaultValue) {
  if (Platform.environment.containsKey(key)) {
    return Platform.environment[key];
  }

  return defaultValue;
}

DateTime getMidnight() {
  DateTime now = new DateTime.now();

  return new DateTime(now.year, now.month, now.day);
}

String buildApiUrl(DateTime startDate, DateTime endDate) {
  String apiDomain = envVarDefault("SCI_TALLY_API_DOMAIN", "localhost:3000");
  String protocol = apiDomain.contains("localhost") ? "http" : "https";

  return "$protocol://$apiDomain/api/v1/orders/tally/sources?since=${startDate.millisecondsSinceEpoch}&until=${endDate.millisecondsSinceEpoch}";
}

Future<http.Response> makeRequest(Uri url, String method,
    {String body = null, Map<String, String> customHeaders = null}) async {
  customHeaders ??= {};

  Map<String, String> headers = new Map.from(customHeaders)
    ..putIfAbsent("Content-Type", () => "application/json")
    ..putIfAbsent("Accept", () => "application/json");
  http.Response resp;

  switch (method.toLowerCase()) {
    case "post":
      resp = await http.post(url, body: body, encoding: Encoding.getByName("UTF8"), headers: headers);
      break;
    case "get":
      resp = await http.get(url, headers: headers);
      break;
    default:
      throw new UnimplementedError("Attempted to create HttpClient with unsupported HTTP method $method.");
  }

  return resp;
}

void ensureSuccessResponse(http.Response resp) {
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    String message = "Request to ${resp.request.url} failed with ${resp.statusCode} ${resp.reasonPhrase}.";

    log.severe("$message Response body: ${resp.body}");

    throw new StateError(message);
  }
}

Future<T> makeGetRequest<T>(String url, [Map<String, String> headers = null]) async {
  var resp = await makeRequest(Uri.parse(url), "GET", customHeaders: headers);

  ensureSuccessResponse(resp);

  return JSON.decode(resp.body);
}

Future<T> makePostRequest<T>(String url, String body, [Map<String, String> headers = null]) async {
  http.Response resp = await makeRequest(Uri.parse(url), "POST", body: body, customHeaders: headers);

  ensureSuccessResponse(resp);

  return JSON.decode(resp.body);
}

SwuMessage buildEmailData(DateTime startDate, DateTime endDate, List<TallyTemplate> tally) {
  final emailDomain = envVarRequired("SCI_TALLY_EMAIL_DOMAIN");
  final bool isLive = envVarDefault("SCI_TALLY_ENV", "development") == "production";
  final swuTemplateId = envVarRequired("SCI_TALLY_SWU_TEMPLATE_ID");
  final formatEmail = (String name) => "$name@$emailDomain";
  final SwuRecipient emailRecipient =
      isLive ? new SwuRecipient("Mike", formatEmail("mikef")) : new SwuRecipient("Joshua Harms", formatEmail("josh"));
  final List<SwuRecipient> ccs = isLive ? JSON.decode(envVarRequired("SCI_TALLY_CC_LIST")) : [];
  final sender =
      new SwuSender("KMSignalR Superintendent", formatEmail("superintendent"), formatEmail("superintendent"));

  return new SwuMessage()
    ..template = swuTemplateId
    ..recipient = emailRecipient
    ..cc = ccs
    ..sender = sender
    ..template_data = (new SwuTallyTemplateData()
      ..startDate = new DateFormat("MMM dd, yyyy").format(startDate)
      ..endDate = new DateFormat("MMM dd, yyyy").format(endDate)
      ..tally = tally);
}

String encode(Object data) {
  dynamic toEncodable(arg) {
    if (arg is Iterable) {
      // JSON codec doesn't know how to encode iterable, but it does know how to encode List.
      // Still doesn't answer the question of why a List<Map> registers as Iterable rather than
      // a List in the first place.
      return arg.toList();
    }

    // This will throw an exception if the object doesn't implement toJson. An exception will be thrown
    // anyway as the codec won't know how to encode it.
    return arg.toJson();
  }

  return JSON.encode(data, toEncodable: toEncodable);
}

Future main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    print('[${rec.level.name}] ${rec.time}: ${rec.message}');
  });

  log.info("SCI Tally Tool starting up.");

  final endDate = getMidnight();
  final startDate = new DateTime(endDate.year, endDate.month, endDate.day - 7);
  final url = buildApiUrl(startDate, endDate);

  log.info("Getting tally from ${url}.");

  Iterable<TallyTemplate> tally = await makeGetRequest<Map<String, int>>(url)
      .then((map) => map.keys.map((key) => new TallyTemplate(key, map[key])));
  SwuMessage emailMessage = buildEmailData(startDate, endDate, tally);
  final swuKey = envVarRequired("SCI_TALLY_SWU_KEY");
  final headers = {
    "Authorization": "Basic ${BASE64.encode(UTF8.encode("$swuKey:"))}",
  };

  Map<String, Object> emailResult =
      await makePostRequest("https://api.sendwithus.com/api/v1/send", encode(emailMessage), headers);

  log.info("Email send result: $emailResult");
}

class TallyTemplate {
  String source;
  int count;

  TallyTemplate(this.source, this.count);

  Map toJson() {
    return {"source": source, "count": count};
  }
}

class SwuRecipient {
  String name;
  String address;

  SwuRecipient(this.name, this.address);

  Map toJson() {
    return {"name": name, "address": address};
  }
}

class SwuSender extends SwuRecipient {
  String replyTo;

  SwuSender(String name, String address, this.replyTo) : super(name, address);

  Map toJson() {
    return super.toJson()..["replyTo"] = replyTo;
  }
}

class SwuTallyTemplateData {
  String startDate;
  String endDate;
  List<TallyTemplate> tally;

  SwuTallyTemplateData();

  Map toJson() {
    tally ??= [];

    return {"startDate": startDate, "endDate": endDate, "tally": tally};
  }
}

class SwuMessage {
  String template;
  SwuRecipient recipient;
  List<SwuRecipient> cc;
  SwuSender sender;
  SwuTallyTemplateData template_data;

  SwuMessage();

  Map toJson() {
    cc ??= [];

    return {
      "template": template,
      "recipient": recipient,
      "cc": cc.map((r) => r.toJson()),
      "sender": sender,
      "template_data": template_data
    };
  }
}
