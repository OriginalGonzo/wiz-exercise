FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN echo "Wiz Support Technical Exercise v3.0" > /app/wizexercise.txt
EXPOSE 3000
USER node
CMD ["node", "server.js"]