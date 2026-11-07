FROM python:3.12.7-slim-bookworm AS build
WORKDIR /src
COPY app.py .
RUN python -m compileall -q -b app.py

FROM python:3.12.7-slim-bookworm
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /src/app.py /src/app.pyc ./
USER 10001:10001
EXPOSE 8080
CMD ["python", "app.py"]
