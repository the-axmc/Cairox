FROM node:20-bullseye AS build

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
ARG VITE_MIDDLEWARE_URL
ENV VITE_MIDDLEWARE_URL=${VITE_MIDDLEWARE_URL}
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost/ || exit 1
