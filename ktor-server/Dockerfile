FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /app
COPY gradlew gradlew.bat settings.gradle.kts build.gradle.kts ./
COPY gradle ./gradle
COPY src ./src
RUN chmod +x gradlew && ./gradlew installDist --no-daemon

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /app/build/install/MochiLedger-SyncServer ./
ENV MOCHI_PORT=8787
ENV MOCHI_DATA_DIR=/data
ENV MOCHI_SYNC_TOKEN=change-me-in-production
VOLUME ["/data"]
EXPOSE 8787
ENTRYPOINT ["./bin/MochiLedger-SyncServer"]
