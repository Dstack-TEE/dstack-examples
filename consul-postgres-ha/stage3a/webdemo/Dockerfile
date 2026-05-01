FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /out/webdemo .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=build /out/webdemo /usr/local/bin/webdemo
ENTRYPOINT ["/usr/local/bin/webdemo"]
