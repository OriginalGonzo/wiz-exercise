const express = require('express');
const mongoose = require('mongoose');
const app = express();
app.use(express.json());

const MONGODB_URI = process.env.MONGODB_URI || 'mongodb://localhost:27017/wizapp';
mongoose.connect(MONGODB_URI);

const TaskSchema = new mongoose.Schema({ title: String, done: Boolean });
const Task = mongoose.model('Task', TaskSchema);

app.get('/', async (req, res) => {
  const tasks = await Task.find();
  res.json({ tasks, message: 'Wiz Exercise App' });
});

app.post('/tasks', async (req, res) => {
  const task = new Task(req.body);
  await task.save();
  res.json(task);
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.use((err, req, res, next) => {
  if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
    return res.status(400).json({ error: 'Invalid JSON' });
  }
  next(err);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));