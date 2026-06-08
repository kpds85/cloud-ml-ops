print("Training: just writing a dummy model file")
with open("/opt/ml/model/model.txt", "w") as f:
    f.write("dummy model")
print("Model training completed, model saved to /opt/ml/model/model.txt")