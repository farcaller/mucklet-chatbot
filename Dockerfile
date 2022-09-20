FROM dart:stable AS build

# Resolve app dependencies.
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

# Copy app source code and AOT compile it.
COPY . .
# Ensure packages are still up-to-date if anything has changed
RUN dart pub get --offline
RUN dart compile exe bin/mucklet_chatbot.dart -o bin/mucklet_chatbot

# Build minimal serving image from AOT-compiled `/server` and required system
# libraries and configuration files stored in `/runtime/` from the build stage.
FROM alpine:latest
COPY --from=build /runtime/ /
COPY --from=build /app/bin/mucklet_chatbot /app/bin/

EXPOSE 8080
CMD ["/app/bin/mucklet_chatbot"]
