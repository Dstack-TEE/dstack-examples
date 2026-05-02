FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /out/bootstrap-secrets .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=build /out/bootstrap-secrets /usr/local/bin/bootstrap-secrets
ENTRYPOINT ["/usr/local/bin/bootstrap-secrets"]
