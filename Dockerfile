# JackpotHood — 自托管部署（Google Cloud Run）
FROM node:20-alpine
WORKDIR /app

# 前端源码 + 部署服务器
COPY frontend/package.json frontend/package-lock.json ./
RUN npm config set fund false
RUN npm ci
COPY frontend/ ./
RUN npm run build

# 自托管服务器（静态托管 + keeper）

ENV PORT=8080
EXPOSE 8080
CMD ["node", "server.mjs"]
