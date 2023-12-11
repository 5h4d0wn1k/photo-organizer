import cv2
import face_recognition
import os
import shutil
from tkinter import *
from tkinter import filedialog
from tkinter import messagebox
from tkinter.ttk import Progressbar
from io import StringIO
import sys

class FaceRecognitionApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Face Recognition App")

        # Initialize GUI components
        self.target_image_path = StringVar()
        self.folder_path = StringVar()
        self.output_folder = StringVar()
        self.tolerance_var = DoubleVar()

        self.create_widgets()

        # Redirect standard output to Tkinter Text widget
        self.text_widget = Text(self.root, height=10, width=50)
        self.text_widget.pack(pady=10)
        sys.stdout = self

    def create_widgets(self):
        # ... (unchanged)
        # Target Image
        target_label = Label(self.root, text="Select the photo of the person whose photo you want to filter.")
        target_entry = Entry(self.root, textvariable=self.target_image_path, state='readonly', width=40)
        target_button = Button(self.root, text="Browse", command=self.select_target_image)

        # Folder Path
        folder_label = Label(self.root, text="Select the Folder you want to organize.")
        folder_entry = Entry(self.root, textvariable=self.folder_path, state='readonly', width=40)
        folder_button = Button(self.root, text="Browse", command=self.select_folder)

        # Output Folder
        output_label = Label(self.root, text="Select the folder where you want to move your images")
        output_entry = Entry(self.root, textvariable=self.output_folder, state='readonly', width=40)
        output_button = Button(self.root, text="Browse", command=self.select_output_folder)

        # Tolerance
        tolerance_label = Label(self.root, text="Accuracy (0.0 - 1.0)")
        tolerance_entry = Entry(self.root, textvariable=self.tolerance_var, width=5)
        self.tolerance_var.set(0.6)

        # Progress Bar
        self.progress_var = DoubleVar()
        progress_bar = Progressbar(self.root, length=200, mode="determinate", variable=self.progress_var)

        # Start Button
        start_button = Button(self.root, text="Start Processing", command=self.start_processing)

        # Pack the GUI components
        target_label.pack(pady=5)
        target_entry.pack(pady=5)
        target_button.pack(pady=5)

        folder_label.pack(pady=5)
        folder_entry.pack(pady=5)
        folder_button.pack(pady=5)

        output_label.pack(pady=5)
        output_entry.pack(pady=5)
        output_button.pack(pady=5)

        tolerance_label.pack(pady=5)
        tolerance_entry.pack(pady=5)

        progress_bar.pack(pady=5)
        start_button.pack(pady=10)

    def select_target_image(self):
        file_path = filedialog.askopenfilename(filetypes=[("Image files", "*.jpg;*.jpeg;*.png;*.webp")])
        self.target_image_path.set(file_path)

    def select_folder(self):
        folder_selected = filedialog.askdirectory()
        self.folder_path.set(folder_selected)

    def select_output_folder(self):
        folder_selected = filedialog.askdirectory()
        self.output_folder.set(folder_selected)

    def process_image(self, image_path, target_encoding, tolerance, no_face_folder):
        try:
            face_encoding = self.encode_faces(image_path)

            if face_encoding is not None and face_recognition.compare_faces(target_encoding, face_encoding, tolerance=tolerance)[0]:
                # Move the matching image to the output folder
                output_path = os.path.join(self.output_folder.get(), os.path.basename(image_path))
                shutil.move(image_path, output_path)
                return 1
            return 0
        except Exception as e:
            print(f"Error processing image {image_path}: {str(e)}")
            return 0

    def encode_faces(self, image_path):
        img = cv2.imread(image_path)
        rgb_img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        face_encodings = face_recognition.face_encodings(rgb_img)
        return face_encodings[0] if face_encodings else None

    def start_processing(self):
        target_image_path = self.target_image_path.get()
        folder_path = self.folder_path.get()
        output_folder = self.output_folder.get()
        tolerance = self.tolerance_var.get()

        # Check if all fields are filled
        if not target_image_path or not folder_path or not output_folder:
            messagebox.showerror("Error", "Please fill in all fields.")
            return

        try:
            # Load target encoding
            target_img = cv2.imread(target_image_path)
            rgb_target_img = cv2.cvtColor(target_img, cv2.COLOR_BGR2RGB)
            target_encoding = face_recognition.face_encodings(rgb_target_img)

            # Loop through each image in the folder with tqdm for progress indication
            image_files = [filename for filename in os.listdir(folder_path) if filename.endswith(('.jpg', '.jpeg', '.png', '.webp'))]
            total_images = len(image_files)

            # Reset progress bar and text widget
            self.progress_var.set(0)
            self.text_widget.delete(1.0, END)

            # Process images periodically using after method
            self.process_images_periodically(target_encoding, tolerance, output_folder, image_files, total_images, 0)

        except Exception as e:
            messagebox.showerror("Error", f"An error occurred: {e}")

    def process_images_periodically(self, target_encoding, tolerance, output_folder, image_files, total_images, processed_images):
        if processed_images < total_images:
            filename = image_files[processed_images]
            image_path = os.path.join(self.folder_path.get(), filename)

            # Process the image against the target encoding
            matches = self.process_image(image_path, target_encoding, tolerance, output_folder)

            # Print the result for the current image
            message = f"\nNumber of matching faces found for {filename}: {matches}"
            self.text_widget.insert(END, message)

            # Update progress bar
            self.progress_var.set(int((processed_images + 1) / total_images * 100))

            # Schedule the next processing after 100 milliseconds
            self.root.after(100, self.process_images_periodically, target_encoding, tolerance, output_folder, image_files, total_images, processed_images + 1)

            # Return for better visualization of progress
            return

        # Show completion message
        messagebox.showinfo("Done", "Image sorting completed!")

    def write(self, text):
        self.text_widget.insert(END, text)
        self.text_widget.see(END)

if __name__ == "__main__":
    root = Tk()
    app = FaceRecognitionApp(root)
    root.mainloop()
