FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /out/mesh-conn .

FROM alpine:3.19
RUN apk add --no-cache iproute2 ca-certificates
COPY --from=build /out/mesh-conn /usr/local/bin/mesh-conn
ENTRYPOINT ["/usr/local/bin/mesh-conn"]
