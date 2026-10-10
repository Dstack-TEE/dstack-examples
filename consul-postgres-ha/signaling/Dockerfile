FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /out/icetest .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=build /out/icetest /usr/local/bin/icetest
ENTRYPOINT ["/usr/local/bin/icetest"]
